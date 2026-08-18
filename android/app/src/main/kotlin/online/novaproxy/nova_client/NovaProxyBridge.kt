package online.novaproxy.nova_client

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Bridges the native VpnService and the Flutter EventChannel.
 *
 * The service emits lifecycle/traffic events through here; [MainActivity]
 * registers the active [EventChannel.EventSink]. Events are always delivered on
 * the main thread, matching the contract documented in SingboxProxyController.
 */
object NovaProxyBridge {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    var state: String = "disconnected"
        private set

    // Application context + active profile name, used to keep the home-screen
    // widget in sync. Set by the service/activity; null before either runs (the
    // widget just shows its saved state until then).
    @Volatile
    var appContext: Context? = null

    @Volatile
    var label: String? = null

    fun setSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun emitState(value: String) {
        state = value
        post(mapOf("type" to "state", "value" to value))
        appContext?.let { NovaWidget.onStateChanged(it, value, label) }
    }

    fun emitError(message: String?) {
        state = "error"
        post(mapOf("type" to "error", "message" to (message ?: "unknown error")))
        appContext?.let { NovaWidget.onStateChanged(it, "error", label) }
    }

    fun emitTraffic(up: Long, down: Long, upTotal: Long, downTotal: Long) {
        post(
            mapOf(
                "type" to "traffic",
                "up" to up,
                "down" to down,
                "upTotal" to upTotal,
                "downTotal" to downTotal,
            ),
        )
    }

    /// Forwards a batch of core log lines. Batched rather than one event per
    /// line because the core emits them in bursts and each event is a hop to the
    /// main thread; the Dart side unpacks the list.
    fun emitLog(lines: List<Map<String, Any>>) {
        post(mapOf("type" to "log", "lines" to lines))
    }

    /// Forwards the core's outbound-group snapshot (the auto-selector and the
    /// per-node urltest latencies it measured through the actual tunnel), so the
    /// server list can show which nodes really work and which one is selected.
    /// Each group is `{tag, selected, items:[{tag, delay}]}`.
    fun emitGroups(groups: List<Map<String, Any?>>) {
        post(mapOf("type" to "groups", "groups" to groups))
    }

    private fun post(event: Map<String, Any?>) {
        val sink = eventSink ?: return
        mainHandler.post { runCatching { sink.success(event) } }
    }
}
