package app.rxlab.rxcode.proto

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Test

class ConfirmationPayloadTest {
    @Test
    fun computerUsePromptReturnsItsDesktopIdWithEitherDecision() {
        val promptId = "70EF8B91-38F7-430F-BFAA-BEFD60D9962D"
        val queue = RxJson.decodeFromString<Payload>(
            """{"type":"confirmation_queue","data":{"confirmations":[{
                "id":"$promptId","sessionID":"thread","title":"Confirm computer use",
                "message":"Allow the agent to control your Mac for the rest of this session?",
                "confirmLabel":"Confirm for This Session","cancelLabel":"Reject","isDestructive":false
            }]}}"""
        ) as Payload.ConfirmationQueue
        val prompt = queue.data.confirmations.single()
        assertEquals("thread", prompt.sessionID)
        assertEquals("Confirm for This Session", prompt.confirmLabel)
        assertEquals("Reject", prompt.cancelLabel)

        for (confirmed in listOf(true, false)) {
            val decision = Payload.ConfirmationDecision(ConfirmationDecisionPayload(prompt.id, confirmed))
            val expected = buildJsonObject {
                put("type", "confirmation_decision")
                put("data", buildJsonObject {
                    put("id", promptId)
                    put("confirmed", confirmed)
                })
            }
            assertEquals(expected, RxJson.parseToJsonElement(RxJson.encodeToString(Payload.serializer(), decision)))
        }
    }
}
