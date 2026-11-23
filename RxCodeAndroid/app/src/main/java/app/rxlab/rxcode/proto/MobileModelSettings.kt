package app.rxlab.rxcode.proto

import kotlinx.serialization.Serializable

@Serializable
data class MobileAgentModel(val provider: String, val id: String, val displayName: String) {
    val key: String get() = "$provider:$id"
}

@Serializable
data class MobileModelSection(val title: String, val models: List<MobileAgentModel>)

@Serializable
data class MobileReasoningLevel(val id: String, val displayName: String)

@Serializable
data class MobileModelSettings(
    val selectedAgentProvider: String? = null,
    val selectedModel: String? = null,
    val selectedEffort: String? = null,
    val modelSections: List<MobileModelSection>? = null,
    val availableModels: List<MobileAgentModel>? = null,
    val reasoningLevelsByModel: Map<String, List<MobileReasoningLevel>>? = null,
) {
    val sections: List<MobileModelSection>
        get() = modelSections?.takeIf { it.isNotEmpty() } ?: availableModels.orEmpty()
            .groupBy { it.provider }
            .map { (provider, models) ->
                val title = when (provider) {
                    "claudeCode" -> "Claude Code"
                    "codex" -> "Codex"
                    "acp" -> "ACP"
                    "localAgent" -> "RxCode Agent"
                    "flowcy" -> "Flowcy"
                    else -> provider
                }
                MobileModelSection(title, models)
            }

    fun levelsFor(model: MobileAgentModel?): List<MobileReasoningLevel> =
        reasoningLevelsByModel?.get(model?.key).orEmpty()

    fun defaultEffortTitle(model: MobileAgentModel?): String {
        val level = levelsFor(model).find { it.id == selectedEffort }
        return level?.let { "Settings (${it.displayName})" } ?: "Agent default"
    }

    fun selection(rememberedModelKey: String?, rememberedEffort: String?): Pair<MobileAgentModel?, String?> {
        val models = sections.flatMap { it.models }
        val remembered = models.find { it.key == rememberedModelKey }
        if (remembered != null) {
            val effort = rememberedEffort?.takeIf { id -> levelsFor(remembered).any { it.id == id } }
            return remembered to effort
        }
        return models.find { it.provider == selectedAgentProvider && it.id == selectedModel } to null
    }
}
