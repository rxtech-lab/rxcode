package app.rxlab.rxcode.proto

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BriefingUsageBaselineTest {
    @Test
    fun readsConfiguredCardsAndCachedObservationsFromTheSwiftSnapshot() {
        val fixture = requireNotNull(javaClass.getResource("/briefing-v1/snapshot.json")).readText()
        val payload = RxJson.decodeFromString<Payload>(fixture) as Payload.Snapshot
        val dashboard = requireNotNull(payload.data.usageDashboard)
        assertEquals(1, dashboard.version)
        assertEquals(14, dashboard.cards.size)
        assertEquals(12, dashboard.snapshots.size)

        val activity = dashboard.snapshots.single { it.pluginID == "ai-usage" }
        assertEquals(payload.data.projects.single().id.toString(), activity.projectID)
        val views = dashboard.cards.filter { it.integrationID == activity.id }
        assertEquals(listOf("summary", "metrics"), views.map { it.style })
        assertEquals(listOf("turns"), views.first().selectedMetricIDs)
        assertTrue(views.first().showInWidget)
        assertEquals(listOf("time", "tokens"), views.last().selectedMetricIDs)

        val limits = dashboard.snapshots.single { it.pluginID == "ai-limits" }
        assertNull(limits.metrics.single { it.id == "codex:5h" }.value)
        assertEquals(0.0, limits.metrics.single { it.id == "codex:7d" }.value)
        val hidden = dashboard.cards.single { it.metricID == "bytes_synced" }
        assertFalse(hidden.isVisible)
        assertTrue(hidden.showInMenuBar)
        val worker = dashboard.snapshots.single { it.scope.endsWith("/ worker:fixture-worker") }
        assertTrue(worker.error.orEmpty().contains("403"))
        assertEquals(Instant.ofEpochSecond(1_778_300_000), worker.fetchedAt)
        assertEquals(70.0, worker.metrics.single { it.id == "requests" }.value)
        assertTrue(dashboard.cards.single { it.integrationID == worker.id }.isVisible)
    }
}
