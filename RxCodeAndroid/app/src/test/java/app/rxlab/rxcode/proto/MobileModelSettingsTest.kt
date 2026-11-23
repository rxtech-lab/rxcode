package app.rxlab.rxcode.proto

import org.junit.Assert.assertEquals
import org.junit.Test

class MobileModelSettingsTest {
    @Test
    fun restoresOnlyAPickSupportedByTheCurrentMac() {
        val codex = MobileAgentModel("codex", "shared", "Codex model")
        val acp = MobileAgentModel("acp", "shared", "ACP model")
        val settings = MobileModelSettings(
            selectedAgentProvider = acp.provider, selectedModel = acp.id,
            availableModels = listOf(codex, acp),
            reasoningLevelsByModel = mapOf(codex.key to listOf(MobileReasoningLevel("high", "High"))),
        )
        assertEquals(codex to "high", settings.selection(codex.key, "high"))
        assertEquals(codex to null, settings.selection(codex.key, "obsolete"))
        assertEquals(acp to null, settings.selection(acp.key, "high"))
        assertEquals(acp to null, settings.selection("missing", "high"))
    }
}
