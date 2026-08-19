package online.novaproxy.nova_client

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and the proxy control/event channels.
 *
 * `nova.proxy/control` (MethodChannel): start / stop / status.
 * `nova.proxy/events`  (EventChannel):  state + traffic stream.
 *
 * Starting the tunnel first requests the system VPN consent dialog
 * ([VpnService.prepare]); on grant it launches [NovaVpnService].
 */
class MainActivity : FlutterActivity() {
    private val controlChannel = "nova.proxy/control"
    private val eventChannel = "nova.proxy/events"
    private val vpnRequestCode = 0x4E56 // "NV"
    private val notifRequestCode = 0x4E4F // "NO"

    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null
    private var pendingXrayConfig: String? = null
    private var pendingLabel: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // So the home-screen widget can be repainted from state changes even
        // before the VpnService has run once this process.
        NovaProxyBridge.appContext = applicationContext
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, controlChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val config = call.argument<String>("configJson")
                    if (config.isNullOrEmpty()) {
                        result.error("no_config", "configJson missing", null)
                        return@setMethodCallHandler
                    }
                    // Present only for an xhttp node: the Xray core config.
                    val xrayConfig = call.argument<String>("xrayConfigJson")
                    // Cosmetic profile name for the ongoing notification.
                    val label = call.argument<String>("label")
                    val consent = VpnService.prepare(this)
                    if (consent != null) {
                        pendingResult = result
                        pendingConfig = config
                        pendingXrayConfig = xrayConfig
                        pendingLabel = label
                        startActivityForResult(consent, vpnRequestCode)
                    } else {
                        startVpn(config, xrayConfig, label)
                        result.success(null)
                    }
                }

                "stop" -> {
                    stopVpn()
                    result.success(null)
                }

                // "Test all servers through the core": run the measuring core
                // (no TUN) over the given config and answer with tag -> delay ms
                // for every node that responded. Live updates also stream out
                // as `groups` events while it runs. Refused while the tunnel is
                // up: libbox allows one command server per process, and every
                // dial would go through the tunnel anyway.
                "measure" -> {
                    val config = call.argument<String>("configJson")
                    val tags = call.argument<List<String>>("tags") ?: emptyList()
                    if (config.isNullOrEmpty()) {
                        result.error("no_config", "configJson missing", null)
                        return@setMethodCallHandler
                    }
                    if (NovaProxyBridge.state != "disconnected" && NovaProxyBridge.state != "error") {
                        result.error("busy", "Disconnect first to measure all servers.", null)
                        return@setMethodCallHandler
                    }
                    NovaMeasure.start(
                        this,
                        config,
                        tags,
                        done = { delays -> result.success(delays) },
                        fail = { why -> result.error("measure_failed", why, null) },
                    )
                }

                "measureCancel" -> {
                    NovaMeasure.cancel()
                    result.success(null)
                }

                "status" -> result.success(NovaProxyBridge.state)

                // Carrier identity for per-ISP optimization. networkOperator is
                // the MCC+MNC of the network the phone is registered on (falls
                // back to the SIM's home operator); neither needs a runtime
                // permission. Empty on Wi-Fi-only / no SIM, which the Dart side
                // treats as "use the default profile".
                "networkInfo" -> {
                    val tm = getSystemService(Context.TELEPHONY_SERVICE)
                        as? TelephonyManager
                    val info = HashMap<String, String>()
                    if (tm != null) {
                        val net = tm.networkOperator ?: ""
                        val sim = tm.simOperator ?: ""
                        info["mccMnc"] = if (net.isNotEmpty()) net else sim
                        info["sim"] = sim
                        info["name"] = tm.networkOperatorName ?: ""
                    }
                    result.success(info)
                }

                // What the bundled core can actually do. The Dart config layer
                // emits AmneziaWG endpoints, and a core built without AmneziaWG
                // takes them and does nothing visible with them, so the Dart
                // side asks before it hands one over. The probe builds a small
                // userspace stack, so it runs off the main thread.
                "coreFeatures" -> {
                    Thread {
                        val supported = NovaCore.supportsAwg(applicationContext)
                        val info = HashMap<String, Any>()
                        // Left out entirely when the probe could not answer, so
                        // the Dart side records "unknown" instead of a verdict.
                        if (supported != null) info["amneziawg"] = supported
                        info["coreVersion"] = NovaCore.version()
                        NovaCore.awgFailureReason()?.let { info["amneziawgReason"] = it }
                        runOnUiThread { result.success(info) }
                    }.start()
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, eventChannel).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    NovaProxyBridge.setSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    NovaProxyBridge.setSink(null)
                }
            },
        )
    }

    /// Ask for POST_NOTIFICATIONS the first time the user connects.
    ///
    /// From Android 13 this is a runtime permission, and without it the
    /// foreground service's ongoing status notification is silently dropped:
    /// the tunnel runs but the user sees no "Connected" card and no Disconnect
    /// action. Asking at connect time (rather than at launch) puts the prompt
    /// where the notification is about to matter. The tunnel starts either way,
    /// so a denial costs the notification, not the connection.
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return
        runCatching {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notifRequestCode,
            )
        }
    }

    private fun startVpn(config: String, xrayConfig: String? = null, label: String? = null) {
        // A measuring core still running would fight the tunnel for the one
        // command server; stop it first (its Dart caller gets what it had).
        NovaMeasure.cancel()
        ensureNotificationPermission()
        val intent = Intent(this, NovaVpnService::class.java)
            .putExtra(NovaVpnService.EXTRA_CONFIG, config)
        if (!xrayConfig.isNullOrEmpty()) {
            intent.putExtra(NovaVpnService.EXTRA_XRAY_CONFIG, xrayConfig)
        }
        if (!label.isNullOrEmpty()) {
            intent.putExtra(NovaVpnService.EXTRA_LABEL, label)
        }
        startService(intent)
    }

    private fun stopVpn() {
        val intent = Intent(this, NovaVpnService::class.java)
            .setAction(NovaVpnService.ACTION_STOP)
        startService(intent)
    }

    @Deprecated("Using onActivityResult for the VpnService consent dialog")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != vpnRequestCode) return
        val result = pendingResult
        val config = pendingConfig
        val xrayConfig = pendingXrayConfig
        val label = pendingLabel
        pendingResult = null
        pendingConfig = null
        pendingXrayConfig = null
        pendingLabel = null
        if (resultCode == Activity.RESULT_OK && config != null) {
            startVpn(config, xrayConfig, label)
            result?.success(null)
        } else {
            NovaProxyBridge.emitError("VPN permission denied")
            result?.error("vpn_denied", "VPN permission denied", null)
        }
    }
}
