package online.novaproxy.nova_client

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.system.OsConstants
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
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
 * The MEASURING core: "test all servers through the core" on Android.
 *
 * A second libbox service with no TUN inbound (so no VPN consent, no route
 * change and no conflict with the tunnel service, which must be down while this
 * runs: libbox allows one command server per process). It is handed the config
 * [SingboxConfig.buildMeasureMap] produces: every usable node as a plain
 * outbound, no routing, no DNS module, and the Clash API on a loopback port.
 *
 * This object only owns the core's LIFETIME. The measuring itself is driven
 * from Dart over that Clash API (see MeasureRunner), one node at a time, so
 * every node gets its own timeout window and gets dialled twice: the first dial
 * pays whatever setup the protocol needs (a mieru session, a NaiveProxy TLS +
 * HTTP/2 connection) and only the second is reported. Letting sing-box's
 * urltest group sweep the pool instead is what used to report 400-800ms for
 * servers that answer in ~110ms.
 *
 * The [PlatformInterface] here is the tunnel service's minus the VPN parts:
 * no TUN (openTun is never called without a tun inbound), no socket protection
 * (there is no VPN to escape), the same interface monitor so the core binds to
 * the real uplink.
 */
object NovaMeasure : PlatformInterface, CommandServerHandler {

    private lateinit var appContext: Context
    private val connectivity: ConnectivityManager by lazy {
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    // ConnectivityManager callbacks are delivered on THIS thread, never on main.
    // report() hands the interface to libbox's updateDefaultInterface, which
    // takes the core's network lock; while the worker is starting or stopping
    // a core that lock is held for seconds, and with the callback on the main
    // thread the whole app froze for that long ("Nova Client isn't
    // responding", seen right after a burst of server switches). The Go side
    // is thread-safe, so a dedicated thread costs nothing.
    private val netmonThread: HandlerThread by lazy {
        HandlerThread("nova-netmon").also { it.start() }
    }
    private val netmonHandler: Handler by lazy { Handler(netmonThread.looper) }

    @Volatile private var server: CommandServer? = null
    @Volatile private var runId = 0
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /**
     * Starts the measuring core on a worker thread and calls [ready] (on the
     * main thread) once its service is up, or [fail] with a reason. The caller
     * then drives the run over the core's Clash API and calls [cancel] when it
     * is done.
     */
    fun start(
        context: Context,
        config: String,
        ready: () -> Unit,
        fail: (String) -> Unit,
        xrayConfig: String? = null,
    ) {
        appContext = context.applicationContext
        val id = ++runId
        Thread({
            var answered = false
            fun answer(error: String?) {
                if (answered) return
                answered = true
                if (error != null) stopInternal()
                mainHandler.post { if (error != null) fail(error) else ready() }
            }
            try {
                stopInternal()
                // xhttp nodes in the pool run on the Xray core; the measuring
                // core reaches them as local socks exits. Start Xray first so
                // its inbounds are up before sing-box dials them. No socket
                // protector: there is no VPN to escape while measuring.
                if (!xrayConfig.isNullOrEmpty()) {
                    val err = io.nekohasekai.novaxray.Novaxray.start(xrayConfig)
                    if (!err.isNullOrEmpty()) return@Thread answer("Xray failed to start: $err")
                    xrayRunning = true
                }
                NovaCore.ensureSetup(appContext)
                val s = CommandServer(this, this)
                s.start()
                server = s
                s.startOrReloadService(config, OverrideOptions())
                if (id != runId) return@Thread answer("cancelled")
                answer(null)
            } catch (e: Throwable) {
                answer(e.message ?: e.toString())
            }
        }, "nova-measure").start()
    }

    /** Stops the measuring core. Safe to call when nothing is running. */
    fun cancel() {
        runId++
        stopInternal()
    }

    val isRunning: Boolean get() = server != null

    @Volatile private var xrayRunning = false

    private fun stopInternal() {
        val s = server
        server = null
        runCatching { s?.closeService() }
        runCatching { s?.close() }
        if (xrayRunning) {
            xrayRunning = false
            runCatching { io.nekohasekai.novaxray.Novaxray.stop() }
        }
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
        val callback = object : ActiveNetworkCallback() {
            override fun onAvailable(network: Network) = report(listener, network)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                report(listener, network)
            override fun onLost(network: Network) {
                if (!active) return
                runCatching { listener.updateDefaultInterface("", -1, false, false) }
            }
        }
        networkCallback = callback
        runCatching {
            when {
                Build.VERSION.SDK_INT >= 31 ->
                    connectivity.registerBestMatchingNetworkCallback(
                        defaultNetworkRequest, callback, netmonHandler,
                    )
                Build.VERSION.SDK_INT >= 28 ->
                    connectivity.requestNetwork(defaultNetworkRequest, callback, netmonHandler)
                else -> if (Build.VERSION.SDK_INT >= 26) {
                        connectivity.registerDefaultNetworkCallback(callback, netmonHandler)
                    } else {
                        connectivity.registerDefaultNetworkCallback(callback)
                    }
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
        val cb = networkCallback as? ActiveNetworkCallback
        if (cb != null && !cb.active) return
        runCatching {
            val name = connectivity.getLinkProperties(network)?.interfaceName ?: return
            val index = JavaNetworkInterface.getByName(name)?.index ?: -1
            listener.updateDefaultInterface(name, index, false, false)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val callback = networkCallback ?: return
        // A callback already queued for delivery must not reach a core that is
        // being torn down (that call blocked on the core's lock, see netmonThread).
        (callback as? ActiveNetworkCallback)?.active = false
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

    /** A NetworkCallback that can be switched off before it is unregistered. */
    private open class ActiveNetworkCallback : ConnectivityManager.NetworkCallback() {
        @Volatile var active = true
    }

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
