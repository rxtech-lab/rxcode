package app.rxlab.rxcode.proto

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteProjectPayloadTest {

    @Test
    fun folderTreePayloadsRoundTrip() {
        val request = Payload.FolderTreeRequest(
            FolderTreeRequestPayload(
                path = "/Users/alex/Code",
                depth = 1,
                includeFiles = false,
            )
        )

        val decodedRequest = RxJson.decodeFromString<Payload>(
            RxJson.encodeToString(Payload.serializer(), request)
        )

        assertTrue(decodedRequest is Payload.FolderTreeRequest)
        assertEquals("/Users/alex/Code", (decodedRequest as Payload.FolderTreeRequest).data.path)

        val result = Payload.FolderTreeResult(
            FolderTreeResultPayload(
                clientRequestID = request.data.clientRequestID,
                requestedPath = "/Users/alex/Code",
                ok = true,
                root = RemoteFolderNode(
                    name = "Code",
                    path = "/Users/alex/Code",
                    children = listOf(
                        RemoteFolderNode(name = "RxCode", path = "/Users/alex/Code/RxCode"),
                    ),
                ),
            )
        )

        val decodedResult = RxJson.decodeFromString<Payload>(
            RxJson.encodeToString(Payload.serializer(), result)
        )

        assertTrue(decodedResult is Payload.FolderTreeResult)
        val data = (decodedResult as Payload.FolderTreeResult).data
        assertEquals(request.data.clientRequestID, data.clientRequestID)
        assertEquals("RxCode", data.root?.children?.firstOrNull()?.name)
    }

    @Test
    fun createProjectPayloadsRoundTrip() {
        val projectId = UUID.fromString("11111111-2222-3333-4444-555555555555")
        val request = Payload.CreateProjectRequest(
            CreateProjectRequestPayload(path = "/Users/alex/Code/RxCode")
        )

        val decodedRequest = RxJson.decodeFromString<Payload>(
            RxJson.encodeToString(Payload.serializer(), request)
        )

        assertTrue(decodedRequest is Payload.CreateProjectRequest)
        assertEquals("/Users/alex/Code/RxCode", (decodedRequest as Payload.CreateProjectRequest).data.path)

        val result = Payload.CreateProjectResult(
            CreateProjectResultPayload(
                clientRequestID = request.data.clientRequestID,
                ok = true,
                project = Project(
                    id = projectId,
                    name = "RxCode",
                    path = "/Users/alex/Code/RxCode",
                ),
            )
        )

        val decodedResult = RxJson.decodeFromString<Payload>(
            RxJson.encodeToString(Payload.serializer(), result)
        )

        assertTrue(decodedResult is Payload.CreateProjectResult)
        val data = (decodedResult as Payload.CreateProjectResult).data
        assertEquals(request.data.clientRequestID, data.clientRequestID)
        assertEquals(projectId, data.project?.id)
        assertEquals("RxCode", data.project?.name)
    }
}
