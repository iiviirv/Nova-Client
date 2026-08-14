package online.novaproxy.nova_client

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
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

    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, controlChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val config = call.argument<String>("configJson")
                    if (config.isNullOrEmpty()) {
                        result.error("no_config", "configJson missing", null)
                        return@setMethodCallHandler
                    }
                    val consent = VpnService.prepare(this)
                    if (consent != null) {
                        pendingResult = result
                        pendingConfig = config
                        startActivityForResult(consent, vpnRequestCode)
                    } else {
                        startVpn(config)
                        result.success(null)
                    }
                }

                "stop" -> {
                    stopVpn()
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

    private fun startVpn(config: String) {
        val intent = Intent(this, NovaVpnService::class.java)
            .putExtra(NovaVpnService.EXTRA_CONFIG, config)
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
        pendingResult = null
        pendingConfig = null
        if (resultCode == Activity.RESULT_OK && config != null) {
            startVpn(config)
            result?.success(null)
        } else {
            NovaProxyBridge.emitError("VPN permission denied")
            result?.error("vpn_denied", "VPN permission denied", null)
        }
    }
}
