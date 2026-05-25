package app.rxlab.rxcode.proto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Mirrors Swift `RunProfile` and its three config variants. iOS keeps `bash` as
 * the only non-optional config and treats `xcode`/`make` as optional bags that
 * coexist with the active `type` — the Android implementation does the same so
 * legacy desktops continue to decode cleanly.
 */
@Serializable
enum class RunProfileType {
    @SerialName("bash") BASH,
    @SerialName("xcode") XCODE,
    @SerialName("make") MAKE,
}

@Serializable
enum class RunStepType {
    @SerialName("bash") BASH,
}

@Serializable
enum class XcodeAction {
    @SerialName("build") BUILD,
    @SerialName("run") RUN,
    @SerialName("test") TEST,
    @SerialName("clean") CLEAN,
}

@Serializable
data class EnvVar(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val key: String = "",
    val value: String = "",
)

@Serializable
data class EnvironmentPreset(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val name: String,
    val loadFromFile: Boolean = false,
    val envFilePath: String? = null,
    val useManualKV: Boolean = true,
    val manualVars: List<EnvVar> = emptyList(),
)

@Serializable
data class BashRunConfig(
    val command: String = "",
    val workingDirectory: String = "",
    val environments: List<EnvironmentPreset> = emptyList(),
    @Serializable(with = UuidSerializer::class) val activePresetId: UUID? = null,
)

@Serializable
data class XcodeDestination(
    val kind: Kind,
    val platform: String,
    val name: String,
    val udid: String? = null,
    val os: String? = null,
    val arch: String? = null,
    val variant: String? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("macOS") MAC_OS,
        @SerialName("macCatalyst") MAC_CATALYST,
        @SerialName("iosSimulator") IOS_SIMULATOR,
        @SerialName("iosDevice") IOS_DEVICE,
        @SerialName("tvSimulator") TV_SIMULATOR,
        @SerialName("tvDevice") TV_DEVICE,
        @SerialName("watchSimulator") WATCH_SIMULATOR,
        @SerialName("watchDevice") WATCH_DEVICE,
        @SerialName("visionSimulator") VISION_SIMULATOR,
        @SerialName("visionDevice") VISION_DEVICE,
        @SerialName("other") OTHER,
    }
}

@Serializable
data class XcodeRunConfig(
    val container: String = "",
    val isWorkspace: Boolean = false,
    val scheme: String = "",
    val configuration: String = "Debug",
    val action: XcodeAction = XcodeAction.RUN,
    val selectedDestination: XcodeDestination? = null,
    val destination: String = "",
)

@Serializable
data class MakeRunConfig(
    val makefile: String = "",
    val target: String = "",
    val arguments: String = "",
)

@Serializable
data class RunStep(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val type: RunStepType = RunStepType.BASH,
    val command: String = "",
)

@Serializable
data class RunProfile(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val name: String,
    val type: RunProfileType = RunProfileType.BASH,
    val bash: BashRunConfig = BashRunConfig(),
    val xcode: XcodeRunConfig? = null,
    val make: MakeRunConfig? = null,
    val beforeSteps: List<RunStep> = emptyList(),
    val afterSteps: List<RunStep> = emptyList(),
    @Serializable(with = SwiftDateSerializer::class) val createdAt: Instant = Instant.now(),
    @Serializable(with = SwiftDateSerializer::class) val updatedAt: Instant = Instant.now(),
)

@Serializable
data class MobileProjectRunProfiles(
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val profiles: List<RunProfile> = emptyList(),
)

/**
 * Mirror of `MobileRunTaskSnapshot`. Status is sent as a string enum on the
 * wire; the Swift side bumps the `terminalOutputTail` periodically so this
 * struct is the source of truth for the "live tail" we surface in the run
 * profiles sheet.
 */
@Serializable
data class MobileRunTaskSnapshot(
    @Serializable(with = UuidSerializer::class) val taskId: UUID,
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    @Serializable(with = UuidSerializer::class) val profileId: UUID,
    val profileName: String,
    val status: Status,
    val statusLabel: String,
    val exitCode: Int? = null,
    @Serializable(with = SwiftDateSerializer::class) val startedAt: Instant,
    val resolvedCwd: String = "",
    val commandPreview: String = "",
    val terminalOutputTail: String? = null,
) {
    @Serializable
    enum class Status {
        @SerialName("running") RUNNING,
        @SerialName("succeeded") SUCCEEDED,
        @SerialName("failed") FAILED,
        @SerialName("signaled") SIGNALED,
        @SerialName("stopped") STOPPED,
    }

    val isRunning: Boolean get() = status == Status.RUNNING
}

@Serializable
data class MobileWebProxyInfo(
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
)
