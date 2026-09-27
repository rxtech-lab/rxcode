package app.rxlab.rxcode.proto

import java.time.Instant
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BriefingPayloadTest {
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
