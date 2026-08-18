package online.novaproxy.nova_client

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews

/**
 * The home-screen status widget. It reflects the tunnel state (updated live by
 * [NovaProxyBridge] on every transition) and opens the app when tapped. Kept
 * deliberately simple: a status surface, not a control, so it needs no VPN
 * consent flow of its own.
 */
class NovaWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        NovaWidget.render(context)
    }
}

object NovaWidget {
    private const val PREFS = "nova_widget"
    private const val KEY_STATE = "state"
    private const val KEY_LABEL = "label"

    // Palette mirrors the app's dark theme (see widget_nova.xml). Native XML
    // cannot read the Flutter tokens, so these are pinned to the same values.
    private const val COLOR_TEXT = 0xFFF5F7FA.toInt()
    private const val COLOR_MUTED = 0xFF8A93A2.toInt()
    private const val COLOR_ON = 0xFF34D399.toInt()
    private const val COLOR_AMBER = 0xFFF5C451.toInt()

    /// Persist the latest state so a freshly added widget (or one redrawn after
    /// process death) shows the truth without waiting for the next transition.
    fun save(context: Context, state: String, label: String?) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_STATE, state)
            .putString(KEY_LABEL, label)
            .apply()
    }

    /// Store the new state and repaint every placed widget. Called from the
    /// bridge on each connect/disconnect so the widget tracks the tunnel live.
    fun onStateChanged(context: Context, state: String, label: String?) {
        save(context, state, label)
        render(context)
    }

    fun render(context: Context) {
        val app = context.applicationContext
        val manager = AppWidgetManager.getInstance(app)
        val ids = manager.getAppWidgetIds(ComponentName(app, NovaWidgetProvider::class.java))
        if (ids.isEmpty()) return

        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val state = prefs.getString(KEY_STATE, "disconnected") ?: "disconnected"
        val label = prefs.getString(KEY_LABEL, null)?.takeIf { it.isNotBlank() }

        val connected = state == "connected"
        val (subtitle, subtitleColor, dot) = when (state) {
            "connected" -> Triple(
                if (label != null) "Connected to $label" else "Connected",
                COLOR_ON,
                R.drawable.widget_dot_on,
            )
            "connecting" -> Triple("Connecting…", COLOR_AMBER, R.drawable.widget_dot_off)
            "disconnecting" -> Triple("Disconnecting…", COLOR_MUTED, R.drawable.widget_dot_off)
            "error" -> Triple("Connection error", COLOR_AMBER, R.drawable.widget_dot_off)
            else -> Triple("Not connected", COLOR_MUTED, R.drawable.widget_dot_off)
        }

        val openPi: PendingIntent? = app.packageManager
            .getLaunchIntentForPackage(app.packageName)
            ?.let { intent ->
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                PendingIntent.getActivity(app, 0, intent, pendingFlags())
            }

        for (id in ids) {
            val views = RemoteViews(app.packageName, R.layout.widget_nova)
            views.setTextViewText(R.id.widget_subtitle, subtitle)
            views.setTextColor(R.id.widget_subtitle, subtitleColor)
            views.setTextColor(R.id.widget_title, if (connected) COLOR_TEXT else COLOR_TEXT)
            views.setImageViewResource(R.id.widget_dot, dot)
            if (openPi != null) views.setOnClickPendingIntent(R.id.widget_root, openPi)
            manager.updateAppWidget(id, views)
        }
    }

    private fun pendingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
}
