package app.rxlab.rxcode.proto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * Skills / ACP / MCP remote-management payloads, mirroring the desktop's
 * `Payload+RemoteManagement.swift`. Each round trip is correlated by
 * `clientRequestID`; the desktop is the source of truth and replies with the
 * authoritative list so mobile never re-derives state locally.
 */

// MARK: - Skills

/** One marketplace plugin flattened from the desktop, plus install state. */
@Serializable
data class MobileSkillPlugin(
    val id: String,
    val name: String,
    val summary: String,
    val author: String,
    val category: String,
    val categoryLabel: String,
    val marketplace: String,
    val marketplaceLabel: String,
    val homepage: String,
    val isInstalled: Boolean,
)

@Serializable
data class MobileSkillSource(
    val id: String,
    val displayName: String,
)

@Serializable
data class SkillCatalogRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val forceRefresh: Boolean = false,
)

@Serializable
data class SkillCatalogResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val ok: Boolean,
    val errorMessage: String? = null,
    val plugins: List<MobileSkillPlugin> = emptyList(),
    val sources: List<MobileSkillSource> = emptyList(),
)

@Serializable
data class SkillMutationRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val operation: Operation,
    val pluginID: String,
) {
    @Serializable
    enum class Operation {
        @SerialName("install") INSTALL,
        @SerialName("uninstall") UNINSTALL,
    }
}

@Serializable
data class SkillMutationResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val operation: SkillMutationRequestPayload.Operation,
    val pluginID: String,
    val ok: Boolean,
    val errorMessage: String? = null,
    val plugins: List<MobileSkillPlugin> = emptyList(),
    val sources: List<MobileSkillSource> = emptyList(),
)

@Serializable
data class SkillSourceMutationRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val operation: Operation,
    val sourceID: String? = null,
    val gitURL: String? = null,
    val ref: String? = null,
) {
    @Serializable
    enum class Operation {
        @SerialName("add") ADD,
        @SerialName("remove") REMOVE,
    }
}

@Serializable
data class SkillSourceMutationResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val operation: SkillSourceMutationRequestPayload.Operation,
    val sourceID: String? = null,
    val ok: Boolean,
    val errorMessage: String? = null,
    val plugins: List<MobileSkillPlugin> = emptyList(),
    val sources: List<MobileSkillSource> = emptyList(),
)

// MARK: - ACP agent clients

@Serializable
data class MobileACPRegistryAgent(
    val id: String,
    val name: String,
    val version: String,
    val summary: String,
    val authors: List<String> = emptyList(),
    val license: String? = null,
    val website: String? = null,
    val iconURL: String? = null,
    val isInstalled: Boolean,
    val hasBinary: Boolean,
    val hasNpx: Boolean,
    val hasUvx: Boolean,
)

@Serializable
data class MobileACPClient(
    val id: String,
    val registryId: String? = null,
    val displayName: String,
    val enabled: Boolean,
    val launchKind: String,
    val modelCount: Int,
    val iconURL: String? = null,
)

@Serializable
data class ACPRegistryRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val forceRefresh: Boolean = false,
)

@Serializable
data class ACPRegistryResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val ok: Boolean,
    val errorMessage: String? = null,
    val registryAgents: List<MobileACPRegistryAgent> = emptyList(),
    val installedClients: List<MobileACPClient> = emptyList(),
)

@Serializable
data class ACPMutationRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val operation: Operation,
    val registryAgentID: String? = null,
    val clientID: String? = null,
    val enabled: Boolean? = null,
) {
    @Serializable
    enum class Operation {
        @SerialName("install") INSTALL,
        @SerialName("uninstall") UNINSTALL,
        @SerialName("setEnabled") SET_ENABLED,
    }
}

@Serializable
data class ACPMutationResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val operation: ACPMutationRequestPayload.Operation,
    val ok: Boolean,
    val errorMessage: String? = null,
    val registryAgents: List<MobileACPRegistryAgent> = emptyList(),
    val installedClients: List<MobileACPClient> = emptyList(),
)

// MARK: - MCP servers

/** Plain key/value pair for MCP environment variables and headers. */
@Serializable
data class MobileMCPKeyValue(
    val key: String,
    val value: String,
)

/** One global MCP server flattened from the desktop's `MCPServerRecord`. */
@Serializable
data class MobileMCPServer(
    val name: String,
    val transport: String,
    val url: String? = null,
    val command: String? = null,
    val args: List<String> = emptyList(),
    val env: List<MobileMCPKeyValue> = emptyList(),
    val headers: List<MobileMCPKeyValue> = emptyList(),
    val isGloballyEnabled: Boolean,
    val endpoint: String,
) {
    /** Mirrors the iOS `id` computed property (servers are keyed by name). */
    val id: String get() = name
}

@Serializable
data class MCPConfigRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
)

@Serializable
data class MCPConfigResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val ok: Boolean,
    val errorMessage: String? = null,
    val servers: List<MobileMCPServer> = emptyList(),
)

@Serializable
data class MCPMutationRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val operation: Operation,
    val serverName: String,
    val server: MobileMCPServer? = null,
    val enabled: Boolean? = null,
) {
    @Serializable
    enum class Operation {
        @SerialName("add") ADD,
        @SerialName("remove") REMOVE,
        @SerialName("setEnabled") SET_ENABLED,
    }
}

@Serializable
data class MCPMutationResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val operation: MCPMutationRequestPayload.Operation,
    val serverName: String,
    val ok: Boolean,
    val errorMessage: String? = null,
    val servers: List<MobileMCPServer> = emptyList(),
)
