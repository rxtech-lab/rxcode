package app.rxlab.rxcode.proto

import kotlinx.serialization.Serializable
import java.time.Instant

@Serializable
data class UsageDashboard(
    val version: Int = 1,
    val cards: List<UsageCardConfiguration> = emptyList(),
    val snapshots: List<UsagePluginSnapshot> = emptyList(),
)

@Serializable
data class UsageCardConfiguration(
    val id: String,
    val integrationID: String,
    val style: String = "summary",
    val metricID: String? = null,
    val isVisible: Boolean = true,
    val showInMenuBar: Boolean = false,
    val showInWidget: Boolean = false,
)

@Serializable
data class UsagePluginSnapshot(
    val id: String,
    val pluginID: String,
    val title: String,
    val projectID: String? = null,
    val scope: String,
    val period: String,
    @Serializable(with = SwiftDateSerializer::class) val fetchedAt: Instant,
    val metrics: List<UsageMetric> = emptyList(),
    val error: String? = null,
)

@Serializable
data class UsageMetric(
    val id: String,
    val title: String,
    val value: Double? = null,
    val unit: String,
    val detail: String? = null,
) {
    val formattedValue: String get() = value?.takeIf { it.isFinite() }?.let { "${java.text.NumberFormat.getNumberInstance().format(it)} $unit" } ?: "Unavailable"
}
