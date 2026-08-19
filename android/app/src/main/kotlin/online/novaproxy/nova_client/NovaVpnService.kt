package online.novaproxy.nova_client

import android.annotation.SuppressLint
import android.app.Notification as AppNotification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import androidx.core.app.NotificationCompat
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaNetworkInterface
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

/**
 * The sing-box tunnel host. Implements the libbox [PlatformInterface] (TUN
 * creation via Android's [VpnService.Builder], socket protection, interface
 * monitoring) and [CommandServerHandler] (lifecycle), and runs the core via the
 * v1.13.x [CommandServer] API.
 *
 * Built against sing-box v1.13.13's libbox. Adapted from the patterns in
 * SagerNet/sing-box-for-android (GPL-3.0).
 */
class NovaVpnService : VpnService(), PlatformInterface, CommandServerHandler {

    companion object {
        const val EXTRA_CONFIG = "config"
        // Present only for an xhttp node: the Xray core config. When set, Xray is
        // started first (with socket protection) and the sing-box [EXTRA_CONFIG]
        // is the TUN->SOCKS bridge that forwards to it.
        const val EXTRA_XRAY_CONFIG = "xrayConfig"
        const val ACTION_STOP = "online.novaproxy.nova_client.STOP"
        // The profile/node name shown in the ongoing notification, if the Dart
        // side passed one. Purely cosmetic; the tunnel runs without it.
        const val EXTRA_LABEL = "label"
        // The auto-select urltest outbound's tag (see SingboxConfig.buildMultiMap).
        const val PROXY_GROUP_TAG = "proxy"

        // The ongoing foreground-service notification. A VpnService that runs
        // past the short start window must post one, and it doubles as the user's
        // "you are protected" status with a one-tap Disconnect.
        private const val NOTIF_CHANNEL_ID = "nova_vpn_status"
        private const val NOTIF_ID = 0x4E56 // 'NV'
    }

    // The active profile's name, for the notification text. Null shows a plain
    // "Connected" without a subtitle.
    private var profileLabel: String? = null

    private var xrayRunning = false

    private val connectivity by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    private var commandServer: CommandServer? = null
    private var statusClient: CommandClient? = null
    private var logClient: CommandClient? = null
    private var groupClient: CommandClient? = null
    private var pfd: ParcelFileDescriptor? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    // The underlying (non-VPN) default network. A bare INTERNET request is used
    // as a REQUEST (not a "default network" listen) on Android 9+ on purpose:
    // registerDefaultNetworkCallback returns the app's OWN VPN interface once the
    // tunnel is up (Android P DP1 behaviour), so sing-box would then treat tun0 as
    // the physical uplink and its `direct` outbound would loop back into the VPN
    // instead of egressing (Cloudflare-direct calls die while the tunnel is up).
    // A REQUEST for a plain internet network resolves to the real Wi-Fi/cellular
    // link, which is what the direct outbound must bind to. Mirrors the upstream
    // sing-box-for-android DefaultNetworkListener.
    private val defaultNetworkRequest by lazy {
        NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
    }

    @Volatile
    private var running = false

    // Every start and stop runs on this one thread, in the order it arrived, so a
    // stop can never run cleanup() while a start is still bringing a core up on
    // another thread. That overlap was the "switch servers quickly and the phone
    // is stuck with a dead VPN" report: the stop found nothing to close yet and
    // said "disconnected", the app sent the next start, a second core came up,
    // then the first one finished, reported "connected" for the old server, and
    // was left holding the TUN with nobody able to stop it.
    private val worker: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "nova-vpn-worker") }

    // Bumped by every start and stop request. A start whose generation is stale
    // by the time its core is up was superseded (the user moved on); it tears
    // that core down instead of reporting "connected", and the newest request
    // owns the state the app sees.
    private val generation = AtomicInteger(0)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            requestStop(startId)
            return START_NOT_STICKY
        }
        val config = intent?.getStringExtra(EXTRA_CONFIG)
        if (config.isNullOrEmpty()) {
            stopSelfSafely(startId)
            return START_NOT_STICKY
        }
        val xrayConfig = intent?.getStringExtra(EXTRA_XRAY_CONFIG)
        val gen = generation.incrementAndGet()
        profileLabel = intent?.getStringExtra(EXTRA_LABEL)?.takeIf { it.isNotBlank() }
        // Let the bridge repaint the home-screen widget on state changes.
        NovaProxyBridge.appContext = applicationContext
        NovaProxyBridge.label = profileLabel
        // Promote to foreground straight away with a "connecting" notification.
        // Android gives a freshly started service only a few seconds to call
        // startForeground before it force-stops us, so this cannot wait for the
        // tunnel to finish coming up on the worker thread.
        startForegroundNotification(getString(R.string.vpn_state_connecting), ongoing = true)
        NovaProxyBridge.emitState("connecting")
        worker.execute {
            // A start while a tunnel is up is a switch, not a no-op (it used to be
            // silently dropped, which left the app on "connecting" until its
            // watchdog gave up): take the old core down first, on this thread.
            if (running || commandServer != null) {
                running = false
                cleanup(keepForeground = true)
            }
            if (gen != generation.get()) {
                // Superseded before it began; the newer request owns the state.
                return@execute
            }
            running = true
            startBox(config, xrayConfig, gen, startId)
        }
        return START_NOT_STICKY
    }

    /// Queue a stop behind whatever the worker is doing. Always ends in a
    /// "disconnected" state event, even when nothing was running (a start that
    /// never got past the consent dialog, or was superseded): the app may be
    /// waiting on that event to sequence the next start, and used to sit on an
    /// eight-second timeout instead.
    private fun requestStop(stopStartId: Int) {
        val gen = generation.incrementAndGet()
        worker.execute {
            if (!running && commandServer == null) {
                NovaProxyBridge.emitState("disconnected")
                stopSelfSafely(stopStartId)
                return@execute
            }
            running = false
            NovaProxyBridge.emitState("disconnecting")
            // If a newer start is already queued behind this stop, leave the
            // foreground promotion its onStartCommand made in place.
            cleanup(keepForeground = gen != generation.get())
            NovaProxyBridge.emitState("disconnected")
            stopSelfSafely(stopStartId)
        }
    }

    /// Runs on the worker only. [gen] is this start's generation; [startId] the
    /// command it came from, so a failure stops only this command and never a
    /// newer start that raced in behind it.
    private fun startBox(config: String, xrayConfig: String?, gen: Int, startId: Int) {
        try {
            // Two-core path: an xhttp node runs on Xray, and sing-box bridges the
            // TUN to it. Start Xray FIRST (with socket protection so its dials
            // bypass the TUN) so its SOCKS inbound is up before sing-box forwards
            // to it.
            if (!xrayConfig.isNullOrEmpty()) startXray(xrayConfig)
            NovaCore.ensureSetup(this)
            val server = CommandServer(this, this)
            server.start()
            commandServer = server
            server.startOrReloadService(config, OverrideOptions())
            if (gen != generation.get()) {
                // A stop or a newer start arrived while this core was coming up.
                // It is not the tunnel the user wants any more: take it down here,
                // on the same thread, so the queued request starts clean, and say
                // nothing; that request owns the state.
                running = false
                cleanup(keepForeground = true)
                return
            }
            NovaProxyBridge.emitState("connected")
            startForegroundNotification(getString(R.string.vpn_state_connected), ongoing = true)
            startStatusClient()
            startLogClient()
            startGroupClient()
        } catch (e: Exception) {
            running = false
            // Only the request the user is still waiting on gets to report the
            // error; a superseded one would paint a failure over the newer
            // request's "connecting".
            if (gen == generation.get()) NovaProxyBridge.emitError(e.message)
            cleanup(keepForeground = gen != generation.get())
            stopSelfSafely(startId)
        }
    }

    // Two-core (xhttp) wiring. Xray ships INSIDE the combined libbox.aar as
    // io.nekohasekai.novaxray, so it shares the one gomobile runtime with
    // sing-box (see tool/core/build-combined-core.sh). Reached only for a single
    // xhttp node, when the Dart side sends EXTRA_XRAY_CONFIG.

    /// Starts the Xray core with [cfg], installing this service as the socket
    /// protector so Xray's outbound dials skip the VPN route (no TUN loop). The
    /// fd is a Long across the gomobile boundary.
    private fun startXray(cfg: String) {
        io.nekohasekai.novaxray.Novaxray.setProtector(
            object : io.nekohasekai.novaxray.Protector {
                override fun protect(fd: Long): Boolean =
                    this@NovaVpnService.protect(fd.toInt())
            })
        // Forward Xray's own log records into the app's core log stream. Without
        // this the Core log is sing-box-only, so an Xray-only failure (e.g. an
        // xhttp transport error on an xhttp node) is invisible. Xray's config
        // loglevel is "warning", so these are tagged warn (3) and survive the
        // quiet filter; the [xray] prefix sets them apart from sing-box lines.
        io.nekohasekai.novaxray.Novaxray.setLogger(
            object : io.nekohasekai.novaxray.Logger {
                override fun log(line: String?) {
                    val msg = line ?: return
                    NovaProxyBridge.emitLog(
                        listOf(mapOf("level" to 3, "message" to "[xray] $msg"))
                    )
                }
            })
        val err = io.nekohasekai.novaxray.Novaxray.start(cfg)
        if (!err.isNullOrEmpty()) {
            throw IllegalStateException("Xray failed to start: $err")
        }
        xrayRunning = true
    }

    private fun stopXray() {
        if (!xrayRunning) return
        xrayRunning = false
        runCatching { io.nekohasekai.novaxray.Novaxray.setLogger(null) }
        runCatching { io.nekohasekai.novaxray.Novaxray.stop() }
    }

    /// Stop this service instance without killing a restart that raced in behind
    /// us. A "switch server" is stop-then-start; the stop runs cleanup on a
    /// background thread and, when it finished, an unconditional stopSelf() would
    /// tear down the *new* tunnel the restart had already established (onDestroy
    /// closes the fresh command server). stopSelf(startId) only stops if no newer
    /// start command has arrived, so the restart survives.
    private fun stopSelfSafely(stopStartId: Int) {
        if (stopStartId >= 0) stopSelf(stopStartId) else stopSelf()
    }

    /// Subscribe to the core's status stream (uplink/downlink bytes-per-second and
    /// running totals) and forward it to the Flutter side so the dashboard's
    /// live speed meter updates. Without this the core still counts traffic but
    /// nothing reads it, so DOWNLOAD/UPLOAD stayed pinned at 0 B/s. Mirrors the
    /// CommandStatus client in sing-box-for-android.
    private fun startStatusClient() {
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandStatus)
                statusInterval = 1_000_000_000L // 1s, in nanoseconds
            }
            val client = CommandClient(StatusHandler(), options)
            statusClient = client
            // The command server is a local socket that may not be accepting the
            // instant after startOrReloadService returns; retry a few times.
            Thread {
                for (attempt in 0 until 10) {
                    if (statusClient !== client) return@Thread
                    if (runCatching { client.connect() }.isSuccess) return@Thread
                    Thread.sleep(300)
                }
            }.start()
        }
    }

    private fun stopStatusClient() {
        val client = statusClient ?: return
        statusClient = null
        runCatching { client.disconnect() }
    }

    /// Subscribe to the core's log stream and forward it to Flutter, where it
    /// backs Settings -> Logs. A SECOND client on purpose: the status client is
    /// what feeds the dashboard's live speed meter, and adding a command to it
    /// would put that at the mercy of the log subscription's lifecycle. Two
    /// clients are cheap (a local socket each) and fail independently.
    ///
    /// How much this carries is set by the config's `log.level`, which the Dart
    /// side raises from `warn` to `info` only when the user asks for detailed
    /// logs.
    private fun startLogClient() {
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandLog)
            }
            val client = CommandClient(LogHandler(), options)
            logClient = client
            // Same race as the status client: the command server's socket may
            // not be accepting the instant startOrReloadService returns.
            Thread {
                for (attempt in 0 until 10) {
                    if (logClient !== client) return@Thread
                    if (runCatching { client.connect() }.isSuccess) return@Thread
                    Thread.sleep(300)
                }
            }.start()
        }
    }

    private fun stopLogClient() {
        val client = logClient ?: return
        logClient = null
        runCatching { client.disconnect() }
    }

    /// Subscribe to the core's outbound-group stream: the auto-selector plus each
    /// pool node's urltest latency, measured through the running tunnel (so the
    /// SNI-block bypass is already applied to those measurements). This is what
    /// lets the server list show a real ping, and which server is selected, for
    /// the clean-IP nodes that can't be probed from outside the tunnel. A THIRD
    /// client for the same reason the log one is separate: independent lifecycle.
    private fun startGroupClient() {
        runCatching {
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandGroup)
                statusInterval = 3_000_000_000L // 3s, in nanoseconds
            }
            val client = CommandClient(GroupHandler(), options)
            groupClient = client
            // Same connect race as the status/log clients: the command server's
            // socket may not be accepting the instant the service returns.
            Thread {
                for (attempt in 0 until 10) {
                    if (groupClient !== client) return@Thread
                    if (runCatching { client.connect() }.isSuccess) {
                        // Force the urltest so every pool node gets a fresh
                        // measurement now, instead of some sitting unmeasured
                        // until the group's own 3-min interval comes around (which
                        // is what left nodes reading "not testable"). A few tries,
                        // because the router may not be routing the instant the
                        // command socket accepts. Best-effort; the interval covers
                        // anything these miss.
                        for (delayMs in longArrayOf(1500L, 4000L, 9000L)) {
                            Thread.sleep(delayMs)
                            if (groupClient !== client) return@Thread
                            runCatching { client.urlTest(PROXY_GROUP_TAG) }
                        }
                        return@Thread
                    }
                    Thread.sleep(300)
                }
            }.start()
        }
    }

    private fun stopGroupClient() {
        val client = groupClient ?: return
        groupClient = null
        runCatching { client.disconnect() }
    }

    /// Receives the core's status callbacks. Only [writeStatus] carries traffic;
    /// the rest are required interface methods and stay no-ops (Nova doesn't use
    /// the log/groups/clash streams here).
    private inner class StatusHandler : CommandClientHandler {
        override fun writeStatus(message: StatusMessage) {
            NovaProxyBridge.emitTraffic(
                message.uplink,
                message.downlink,
                message.uplinkTotal,
                message.downlinkTotal,
            )
        }

        override fun connected() {}
        override fun disconnected(message: String?) {}
        override fun clearLogs() {}
        override fun writeLogs(messageList: LogIterator?) {}
        override fun writeGroups(message: OutboundGroupIterator?) {}
        override fun writeConnectionEvents(events: ConnectionEvents?) {}
        override fun setDefaultLogLevel(level: Int) {}
        override fun initializeClashMode(modeList: StringIterator, currentMode: String) {}
        override fun updateClashMode(newMode: String) {}
    }

    /// Receives the core's log stream. Only [writeLogs] carries anything; the
    /// rest are required interface methods.
    private inner class LogHandler : CommandClientHandler {
        override fun writeLogs(messageList: LogIterator?) {
            val list = messageList ?: return
            val batch = ArrayList<Map<String, Any>>()
            while (list.hasNext()) {
                val entry = list.next() ?: continue
                batch.add(
                    mapOf(
                        "level" to entry.level,
                        "message" to (entry.message ?: ""),
                    )
                )
            }
            if (batch.isNotEmpty()) NovaProxyBridge.emitLog(batch)
        }

        override fun writeStatus(message: StatusMessage) {}
        override fun connected() {}
        override fun disconnected(message: String?) {}
        override fun clearLogs() {}
        override fun writeGroups(message: OutboundGroupIterator?) {}
        override fun writeConnectionEvents(events: ConnectionEvents?) {}
        override fun setDefaultLogLevel(level: Int) {}
        override fun initializeClashMode(modeList: StringIterator, currentMode: String) {}
        override fun updateClashMode(newMode: String) {}
    }

    /// Receives the core's outbound-group snapshots. Only [writeGroups] carries
    /// anything; it flattens each group and its items' urltest delays into plain
    /// maps for the Dart side, which maps the `node-i` tags back to real servers.
    private inner class GroupHandler : CommandClientHandler {
        override fun writeGroups(message: OutboundGroupIterator?) {
            val groups = message ?: return
            val out = ArrayList<Map<String, Any?>>()
            while (groups.hasNext()) {
                val group = groups.next() ?: continue
                val items = ArrayList<Map<String, Any?>>()
                val itemIterator = group.items
                while (itemIterator != null && itemIterator.hasNext()) {
                    val item = itemIterator.next() ?: continue
                    items.add(
                        mapOf(
                            "tag" to item.tag,
                            // urlTestDelay is ms; 0 means no successful test yet.
                            "delay" to item.urlTestDelay,
                        )
                    )
                }
                out.add(
                    mapOf(
                        "tag" to group.tag,
                        "selected" to group.selected,
                        "items" to items,
                    )
                )
            }
            if (out.isNotEmpty()) NovaProxyBridge.emitGroups(out)
        }

        override fun writeStatus(message: StatusMessage) {}
        override fun connected() {}
        override fun disconnected(message: String?) {}
        override fun clearLogs() {}
        override fun writeLogs(messageList: LogIterator?) {}
        override fun writeConnectionEvents(events: ConnectionEvents?) {}
        override fun setDefaultLogLevel(level: Int) {}
        override fun initializeClashMode(modeList: StringIterator, currentMode: String) {}
        override fun updateClashMode(newMode: String) {}
    }

    /// Tears the core, Xray, the TUN and the clients down. [keepForeground]
    /// leaves the foreground notification alone, for the switch case where a
    /// newer start has already posted its own "connecting" card.
    private fun cleanup(keepForeground: Boolean = false) {
        stopGroupClient()
        stopLogClient()
        stopStatusClient()
        runCatching { commandServer?.closeService() }
        runCatching { commandServer?.close() }
        commandServer = null
        stopXray()
        runCatching { pfd?.close() }
        pfd = null
        if (keepForeground) return
        // Drop the ongoing notification. STOP_FOREGROUND_REMOVE clears it rather
        // than leaving a stale "Connected" card behind after we disconnect.
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        }
    }

    /// Build (channel + content) and post the ongoing foreground notification.
    /// Called once with "connecting" the moment the service starts (Android
    /// requires startForeground within a few seconds) and again with "connected"
    /// once the tunnel is up. The card carries the active profile name and a
    /// one-tap Disconnect.
    private fun startForegroundNotification(state: String, ongoing: Boolean) {
        ensureNotificationChannel()

        // Tap opens the app; the Disconnect action stops the tunnel without it.
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentPi = openIntent?.let {
            PendingIntent.getActivity(this, 0, it, pendingIntentFlags())
        }
        val stopPi = PendingIntent.getService(
            this,
            1,
            Intent(this, NovaVpnService::class.java).setAction(ACTION_STOP),
            pendingIntentFlags(),
        )

        // The status-bar icon must be monochrome (Android tints it flat), so it
        // stays the simple mark. The large icon shows the real full-colour Nova
        // logo as the notification's main circle, which is what a user actually
        // recognises.
        val largeIcon = runCatching {
            BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher)
        }.getOrNull()

        val builder = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_nova)
            .apply { if (largeIcon != null) setLargeIcon(largeIcon) }
            .setContentTitle(state)
            .setContentText(profileLabel ?: getString(R.string.app_name))
            .setOngoing(ongoing)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(
                0,
                getString(R.string.vpn_action_disconnect),
                stopPi,
            )
        if (contentPi != null) builder.setContentIntent(contentPi)

        val notification: AppNotification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    /// The status channel is created once, lazily. Low importance so the ongoing
    /// card is silent (no sound or heads-up); it is a status surface, not an
    /// alert. No-op below Android 8, which has no notification channels.
    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (mgr.getNotificationChannel(NOTIF_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            NOTIF_CHANNEL_ID,
            getString(R.string.vpn_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.vpn_channel_desc)
            setShowBadge(false)
            lockscreenVisibility = AppNotification.VISIBILITY_PUBLIC
        }
        mgr.createNotificationChannel(channel)
    }

    /// Immutable PendingIntents everywhere (required target-side from Android 12).
    private fun pendingIntentFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

    override fun onDestroy() {
        // Invalidate any start still in flight so it tears its core down when it
        // finishes, then close what is up. Done on the worker so it can never
        // run alongside a start; the worker keeps this object alive until done.
        generation.incrementAndGet()
        runCatching {
            worker.execute {
                running = false
                cleanup()
            }
            worker.shutdown()
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        requestStop(-1)
        super.onRevoke()
    }

    // ---- CommandServerHandler ----

    override fun serviceStop() {
        requestStop(-1)
    }

    override fun serviceReload() {
        // Single-profile client: nothing to reload.
    }

    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().apply {
            setAvailable(false)
            setEnabled(false)
        }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {
        // System HTTP proxy not exposed yet.
    }

    override fun writeDebugMessage(message: String?) {
        // No-op; box logs go to logcat via the core.
    }

    // ---- PlatformInterface ----

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession("Nova Client")
            .setMtu(options.getMTU())

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        val inet4 = options.getInet4Address()
        while (inet4.hasNext()) {
            val a = inet4.next()
            builder.addAddress(a.address(), a.prefix())
        }
        val inet6 = options.getInet6Address()
        var hasV6 = false
        while (inet6.hasNext()) {
            val a = inet6.next()
            builder.addAddress(a.address(), a.prefix())
            hasV6 = true
        }

        if (options.getAutoRoute()) {
            // Route everything into the TUN; sing-box hijacks DNS via sniff, so a
            // placeholder resolver address is sufficient here.
            builder.addDnsServer("1.1.1.1")
            builder.addRoute("0.0.0.0", 0)
            if (hasV6) builder.addRoute("::", 0)

            val include = options.getIncludePackage()
            while (include.hasNext()) {
                runCatching { builder.addAllowedApplication(include.next()) }
            }
            val exclude = options.getExcludePackage()
            while (exclude.hasNext()) {
                runCatching { builder.addDisallowedApplication(exclude.next()) }
            }
        }

        val descriptor = builder.establish() ?: error("android: VPN establish failed")
        pfd = descriptor
        return descriptor.fd
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("unsupported")
        val uid = connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        return ConnectionOwner().apply { setUserId(uid) }
    }

    @SuppressLint("NewApi")
    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = report(listener, network)
            override fun onCapabilitiesChanged(
                network: Network,
                caps: NetworkCapabilities,
            ) = report(listener, network)

            override fun onLost(network: Network) {
                runCatching { listener.updateDefaultInterface("", -1, false, false) }
            }
        }
        networkCallback = callback
        // Pick the registration that returns the real underlying network, never
        // the VPN's own tun interface (see [defaultNetworkRequest]). Matches the
        // per-SDK strategy in sing-box-for-android's DefaultNetworkListener.
        runCatching {
            when {
                // registerBestMatchingNetworkCallback tracks THE default network
                // matching the request, excluding our VPN.
                Build.VERSION.SDK_INT >= 31 ->
                    connectivity.registerBestMatchingNetworkCallback(
                        defaultNetworkRequest, callback, mainHandler,
                    )
                // Android 9/10: registerDefaultNetworkCallback returns the VPN
                // interface, so a REQUEST is required to get the physical uplink.
                Build.VERSION.SDK_INT >= 28 ->
                    connectivity.requestNetwork(defaultNetworkRequest, callback, mainHandler)
                // Pre-9 default callback still reports the underlying network.
                else ->
                    connectivity.registerDefaultNetworkCallback(callback)
            }
        }
        // Report the network we can already see, synchronously. Every
        // registration above delivers its first onAvailable on a handler, so on
        // a fast start the core reaches the stage that opens its own sockets
        // before that callback arrives, and anything binding to the default
        // interface (the AmneziaWG and WireGuard endpoints both do) fails with
        // "no available network interface" on a device that is perfectly
        // online. Reproduced as an intermittent connect failure; there is
        // nothing emulator-specific about the race.
        // The VPN's own interface is skipped for the reason in
        // [defaultNetworkRequest]: reporting tun0 as the uplink makes the direct
        // outbound loop back into the tunnel.
        runCatching {
            val current = connectivity.activeNetwork ?: return@runCatching
            val caps = connectivity.getNetworkCapabilities(current) ?: return@runCatching
            // The same predicate [defaultNetworkRequest] uses, so this shortcut
            // can never report a network the callback path would have rejected.
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return@runCatching
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            ) {
                return@runCatching
            }
            report(listener, current)
        }
    }

    private fun report(listener: InterfaceUpdateListener, network: Network) {
        runCatching {
            val name = connectivity.getLinkProperties(network)?.interfaceName ?: return
            val index = JavaNetworkInterface.getByName(name)?.index ?: -1
            listener.updateDefaultInterface(name, index, false, false)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val callback = networkCallback ?: return
        runCatching { connectivity.unregisterNetworkCallback(callback) }
        networkCallback = null
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val interfaces = mutableListOf<LibboxNetworkInterface>()
        runCatching {
            for (ni in JavaNetworkInterface.getNetworkInterfaces()) {
                val boxIf = LibboxNetworkInterface()
                boxIf.setName(ni.name)
                boxIf.setIndex(ni.index)
                runCatching { boxIf.setMTU(ni.mtu) }
                val addrs = mutableListOf<String>()
                for (ia in ni.interfaceAddresses) {
                    // Strip any IPv6 zone id ("fe80::1%wlan0"): sing-box 1.13 feeds
                    // these straight into netip.ParsePrefix, which rejects a zone
                    // in a prefix and PANICS (SIGABRT), crashing the whole app on
                    // connect. Every device has zoned link-local addresses, so
                    // dropping the "%zone" suffix here is required, not cosmetic.
                    val host = (ia.address.hostAddress ?: continue).substringBefore('%')
                    addrs.add("$host/${ia.networkPrefixLength}")
                }
                boxIf.setAddresses(StringArray(addrs.iterator()))
                var flags = 0
                if (ni.isUp) flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                if (ni.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
                if (ni.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
                if (ni.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
                boxIf.setFlags(flags)
                interfaces.add(boxIf)
            }
        }
        return InterfaceArray(interfaces.iterator())
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun readWIFIState(): WIFIState? = null

    override fun systemCertificates(): StringIterator =
        StringArray(emptyList<String>().iterator())

    override fun clearDNSCache() {}

    override fun sendNotification(notification: Notification) {}

    private class StringArray(private val iterator: Iterator<String>) : StringIterator {
        override fun len(): Int = 0
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): String = iterator.next()
    }

    private class InterfaceArray(
        private val iterator: Iterator<LibboxNetworkInterface>,
    ) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): LibboxNetworkInterface = iterator.next()
    }
}
