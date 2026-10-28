package app.rxlab.rxcode.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import app.rxlab.rxcode.MainActivity
import app.rxlab.rxcode.R
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.proto.UsageDashboard
import java.time.Duration
import java.time.Instant

class UsageWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val saved = context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE).getString("dashboard", null)
        val dashboard = saved?.let { runCatching { RxJson.decodeFromString<UsageDashboard>(it) }.getOrNull() } ?: UsageDashboard()
        val rows = dashboard.cards.filter { it.showInWidget }.take(3).mapNotNull { card ->
            dashboard.snapshots.firstOrNull { it.id == card.integrationID }?.let { snapshot ->
                val metric = snapshot.metrics.firstOrNull { card.includesMetric(it.id) }
                val stale = snapshot.error != null || Duration.between(snapshot.fetchedAt, Instant.now()).seconds > 3600
                "${snapshot.title}\n${metric?.let { "${it.title}: ${it.formattedValue}" } ?: "No data"}\n${snapshot.period}${if (stale) " · Stale" else ""}"
            }
        }
        ids.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.usage_widget)
            views.setTextViewText(R.id.usage_widget_content, rows.joinToString("\n\n").ifEmpty { "Select usage cards in Briefing on your Mac" })
            views.setOnClickPendingIntent(R.id.usage_widget_content, PendingIntent.getActivity(context, 0,
                Intent(context, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            manager.updateAppWidget(id, views)
        }
    }
    companion object {
        fun save(context: Context, dashboard: UsageDashboard) {
            val cards = dashboard.cards.filter { it.showInWidget }.take(3)
            val compact = dashboard.copy(cards = cards, snapshots = dashboard.snapshots.filter { row -> cards.any { it.integrationID == row.id } })
            context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE).edit()
                .putString("dashboard", RxJson.encodeToString(UsageDashboard.serializer(), compact)).apply()
            val manager = AppWidgetManager.getInstance(context)
            UsageWidgetProvider().onUpdate(context, manager, manager.getAppWidgetIds(ComponentName(context, UsageWidgetProvider::class.java)))
        }
    }
}
