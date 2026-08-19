package online.novaproxy.nova_client

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.OsConstants
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.InetSocketAddress
import java.net.NetworkInterface as JavaNetworkInterface
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

/**
 * The MEASURING core: "test all servers through the core" on Android.
 *
 * A second libbox service with no TUN inbound (so no VPN consent, no route
 * change and no conflict with the tunnel service, which must be down while this
 * runs: libbox allows one command server per process). It is handed the config
 * [SingboxConfig.buildMeasureMap] produces, every usable node behind the `proxy`
 * urltest group, asks the core to test the group, and forwards the group's
 * per-node delays to Dart through the same `groups` event the tunnel uses, so
 * the node list fills in live. When every node has answered, or the results
 * have been quiet for a while, or the budget is spent, it reports the final
 * delays and shuts the core down.
 *
 * The [PlatformInterface] here is the tunnel service's minus the VPN parts:
 * no TUN (openTun is never called without a tun inbound), no socket protection
 * (there is no VPN to escape), the same interface monitor so the core binds to
 * the real uplink.
 */
object NovaMeasure : PlatformInterface, CommandServerHandler {

    private const val GROUP_TAG = NovaVpnService.PROXY_GROUP_TAG

    /** Whole-run budget. sing-box tests ten nodes at a time, 5s each. */
    private const val BUDGET_MS = 60_000L

    /** After the first answers, stop when nothing new arrived for this long. */
    private const val QUIET_MS = 8_000L

    private const val MIN_RUN_MS = 12_000L

    private lateinit var appContext: Context
    private val connectivity: ConnectivityManager by lazy {
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    @Volatile private var server: CommandServer? = null
    @Volatile private var client: CommandClient? = null
    @Volatile private var runId = 0
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    // Latest delays by tag, as the group handler reports them.
    private val latest = HashMap<String, Int>()
    @Volatile private var lastChangeAt = 0L

    /**
     * Runs one measuring pass on a worker thread. [config] is the measuring
     * config, [tags] the `node-i` tags (or the single `proxy`) to wait for.
     * Calls [done] exactly once, on the main thread, with tag -> delay ms for
     * every node that answered (a missing tag is "no response"), or [fail]
     * with a reason if the core could not start.
     */
    fun start(
        context: Context,
        config: String,
        tags: List<String>,
        done: (Map<String, Int>) -> Unit,
        fail: (String) -> Unit,
    ) {
        appContext = context.applicationContext
        val id = ++runId
        Thread({
            var finished = false
            fun finish(result: Map<String, Int>?, error: String?) {
                if (finished) return
                finished = true
                stopInternal()
                mainHandler.post {
                    if (error != null) fail(error) else done(result ?: emptyMap())
                }
            }
            try {
                stopInternal()
                synchronized(latest) { latest.clear() }
                NovaCore.ensureSetup(appContext)
                val s = CommandServer(this, this)
                s.start()
                server = s
                s.startOrReloadService(config, OverrideOptions())
                if (id != runId) return@Thread finish(null, "cancelled")

                // Group stream: the per-node urltest delays as they land.
                val options = CommandClientOptions().apply {
                    addCommand(Libbox.CommandGroup)
                    statusInterval = 1_000_000_000L // 1s
                }
                val c = CommandClient(GroupHandler(tags.toSet()), options)
                client = c
                var connected = false
                for (attempt in 0 until 20) {
                    if (runCatching { c.connect() }.isSuccess) {
                        connected = true
                        break
                    }
                    Thread.sleep(250)
                }
                if (!connected) return@Thread finish(null, "could not talk to the measuring core")
                // Kick the test. The urltest group also runs its own first pass
                // at startup; either lands in the group stream below. A
                // "test already running" reply here is fine.
                runCatching { c.urlTest(GROUP_TAG) }

                val startedAt = System.currentTimeMillis()
                lastChangeAt = startedAt
                var lastCount = -1
                while (true) {
                    Thread.sleep(500)
                    if (id != runId) break
                    val now = System.currentTimeMillis()
                    val count = synchronized(latest) { latest.size }
                    if (count != lastCount) {
                        lastCount = count
                        lastChangeAt = now
                    }
                    if (count >= tags.size) break
                    if (now - startedAt > BUDGET_MS) break
                    if (count > 0 && now - lastChangeAt > QUIET_MS && now - startedAt > MIN_RUN_MS) break
                }
                finish(synchronized(latest) { HashMap(latest) }, null)
            } catch (e: Throwable) {
                finish(null, e.message ?: e.toString())
            }
        }, "nova-measure").start()
    }

    /** Stops a run in progress; its [start] callback then fires with what it has. */
    fun cancel() {
        runId++
    }

    val isRunning: Boolean get() = server != null

    private fun stopInternal() {
        val c = client
        client = null
        runCatching { c?.disconnect() }
        val s = server
        server = null
        runCatching { s?.closeService() }
        runCatching { s?.close() }
    }

    private class GroupHandler(private val wanted: Set<String>) : CommandClientHandler {
        override fun writeGroups(message: OutboundGroupIterator?) {
            val groups = message ?: return
            val out = ArrayList<Map<String, Any?>>()
            while (groups.hasNext()) {
                val group = groups.next() ?: continue
                val items = ArrayList<Map<String, Any?>>()
                val it = group.items
                while (it != null && it.hasNext()) {
                    val item = it.next() ?: continue
                    val delay = item.urlTestDelay
                    items.add(mapOf("tag" to item.tag, "delay" to delay))
                    if (group.tag == GROUP_TAG && delay > 0 && wanted.contains(item.tag)) {
                        synchronized(latest) { latest[item.tag] = delay }
                    }
                }
                out.add(mapOf("tag" to group.tag, "selected" to group.selected, "items" to items))
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

    // ---- CommandServerHandler ----

    override fun serviceReload() {}
    override fun serviceStop() { cancel() }
    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().apply {
            setAvailable(false)
            setEnabled(false)
        }
    override fun setSystemProxyEnabled(isEnabled: Boolean) {}
    override fun writeDebugMessage(message: String?) {}

    // ---- PlatformInterface (no VPN) ----

    override fun localDNSTransport(): LocalDNSTransport? = null

    // No VPN is up while measuring, so there is nothing to protect sockets
    // from; saying we handle it keeps the core from trying to bind interfaces
    // itself, exactly as the tunnel service does.
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun autoDetectInterfaceControl(fd: Int) {}

    override fun openTun(options: TunOptions): Int =
        throw IllegalStateException("the measuring core has no TUN")

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

    private val defaultNetworkRequest by lazy {
        NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
    }

    @SuppressLint("NewApi")
    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = report(listener, network)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                report(listener, network)
            override fun onLost(network: Network) {
                runCatching { listener.updateDefaultInterface("", -1, false, false) }
            }
        }
        networkCallback = callback
        runCatching {
            when {
                Build.VERSION.SDK_INT >= 31 ->
                    connectivity.registerBestMatchingNetworkCallback(
                        defaultNetworkRequest, callback, mainHandler,
                    )
                Build.VERSION.SDK_INT >= 28 ->
                    connectivity.requestNetwork(defaultNetworkRequest, callback, mainHandler)
                else -> connectivity.registerDefaultNetworkCallback(callback)
            }
        }
        // Same synchronous first report as the tunnel service: the core opens
        // its sockets before the callback's first onAvailable arrives.
        runCatching {
            val current = connectivity.activeNetwork ?: return@runCatching
            val caps = connectivity.getNetworkCapabilities(current) ?: return@runCatching
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
                    // Strip IPv6 zone ids; sing-box 1.13 panics on them (see the
                    // tunnel service's getInterfaces).
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
    override fun systemCertificates(): StringIterator = StringArray(emptyList<String>().iterator())
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
