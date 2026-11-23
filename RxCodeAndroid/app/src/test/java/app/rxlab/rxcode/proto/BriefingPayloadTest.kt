package app.rxlab.rxcode.proto

import app.rxlab.rxcode.ui.briefing.groupBriefings
import java.time.ZoneOffset
import java.time.Instant
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BriefingPayloadTest {
    @Test
    fun swiftSnapshotGroupsPlanOnlyDayAndPreservesLegacyDecoding() {
        val id = UUID.randomUUID()
        val project = UUID.randomUUID()
        val raw = """
            {"type":"snapshot","data":{"projects":[],"sessions":[],
             "branchBriefings":[{"projectId":"$project","branch":"main","briefing":"Previous day","updatedAt":0,"day":0}],
             "briefingPlans":[{"id":"$id","projectID":"$project","threadID":"draft","branch":"main",
             "title":"Extension support","updatedAt":90000,"planningStatus":"ready","implementationStatus":"unimplemented",
             "implementationEvidence":"No implementation started","versionCount":3,"currentVersionTitle":"Final design",
             "featureExcerpt":"- Discover extensions","futureField":true}]}}
        """.trimIndent()
        val snapshot = (RxJson.decodeFromString<Payload>(raw) as Payload.Snapshot).data
        val groups = groupBriefings(snapshot.branchBriefings.orEmpty(), emptyList(), snapshot.briefingPlans.orEmpty(), ZoneOffset.UTC)
        assertEquals(2, groups.size)
        val plan = groups.first().plans.single()
        assertEquals(id, plan.id)
        assertEquals(3, plan.versionCount)
        assertEquals("ready", plan.planningStatus)
        assertEquals("unimplemented", plan.implementationStatus)
        assertEquals(null, groups.first().briefing)
        assertEquals("Previous day", groups.last().briefing?.briefing)
        val legacy = RxJson.decodeFromString<SnapshotPayload>("""{"projects":[],"sessions":[]}""")
        assertEquals(null, legacy.briefingPlans)
    }

    @Test
    fun documentSnapshotAndContentRoundTrip() {
        val id = UUID.fromString("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        val document = MobileBriefingDocument(
            id = id, title = "Release notes", format = "markdown",
            createdAt = Instant.parse("2026-09-27T00:00:00Z"),
            updatedAt = Instant.parse("2026-09-27T01:00:00Z"),
        )
        val snapshot = Payload.Snapshot(SnapshotPayload(briefingDocuments = listOf(document)))
        val decodedSnapshot = RxJson.decodeFromString<Payload>(
            RxJson.encodeToString(Payload.serializer(), snapshot)
        )
        assertTrue(decodedSnapshot is Payload.Snapshot)
        assertEquals(id, (decodedSnapshot as Payload.Snapshot).data.briefingDocuments?.single()?.id)

        val requestId = UUID.randomUUID()
        val result = Payload.BriefingContentResult(BriefingContentResultPayload(
            clientRequestID = requestId, briefingID = id, ok = true,
            content = "# Release notes", assets = listOf(MobileBriefingAsset("images/chart.png", 42)),
        ))
        val decodedResult = RxJson.decodeFromString<Payload>(
            RxJson.encodeToString(Payload.serializer(), result)
        )
        assertTrue(decodedResult is Payload.BriefingContentResult)
        assertEquals("# Release notes", (decodedResult as Payload.BriefingContentResult).data.content)

        val chunk = Payload.BriefingContentResult(BriefingContentResultPayload(
            clientRequestID = requestId, briefingID = id, assetPath = "images/chart.png",
            ok = true, assetBase64 = "AQID", assetOffset = 512, assetTotalBytes = 1024,
        ))
        val decodedChunk = RxJson.decodeFromString<Payload>(
            RxJson.encodeToString(Payload.serializer(), chunk)
        ) as Payload.BriefingContentResult
        assertEquals(512L, decodedChunk.data.assetOffset)
        assertEquals(1024L, decodedChunk.data.assetTotalBytes)
    }
}

class UsageDashboardPayloadTest {
    @Test
    fun multipleMetricsAndLegacySelectionDecode() {
        val legacy = RxJson.decodeFromString<UsageCardConfiguration>("""{"id":"c","integrationID":"i","metricID":"tokens"}""")
        assertTrue(legacy.includesMetric("tokens"))
        assertEquals(false, legacy.includesMetric("time"))
        val multiple = RxJson.decodeFromString<UsageCardConfiguration>("""{"id":"c","integrationID":"i","metricID":"tokens","metricIDs":["tokens","time"]}""")
        assertTrue(multiple.includesMetric("time"))
        assertEquals(false, multiple.includesMetric("turns"))
        val all = RxJson.decodeFromString<UsageCardConfiguration>("""{"id":"c","integrationID":"i","metricID":"tokens","metricIDs":[]}""")
        assertTrue(all.includesMetric("future-metric"))
    }
    @Test
    fun swiftUsageSnapshotDecodesWithUnknownFields() {
        val payload = RxJson.decodeFromString<Payload>("""{"type":"snapshot","data":{"projects":[],"sessions":[],"usageDashboard":{"version":1,"integrations":[{"id":"a","oauth":{"clientID":"public"}}],"cards":[{"id":"card","integrationID":"a","style":"future-style"}],"snapshots":[{"id":"a","pluginID":"ai-usage","title":"AI","scope":"All projects","period":"Last 7 days","fetchedAt":0,"metrics":[{"id":"tokens","title":"Tokens","value":120,"unit":"tokens"}]}]}}}""") as Payload.Snapshot
        assertEquals(120.0, payload.data.usageDashboard?.snapshots?.single()?.metrics?.single()?.value)
        assertEquals("future-style", payload.data.usageDashboard?.cards?.single()?.style)
        val old = RxJson.decodeFromString<Payload>("""{"type":"snapshot","data":{"projects":[],"sessions":[]}}""") as Payload.Snapshot
        assertEquals(null, old.data.usageDashboard)
    }
}
