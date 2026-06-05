package app.rxlab.rxcode.proto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID

/**
 * Kotlin mirror of `RxCodeCore/Menu/MenuItem.swift`. The desktop is the single
 * source of truth for context menus: it builds `[MenuItem]` from its hooks and
 * ships the tree as JSON over the autopilot relay (`menuForProject` /
 * `menuForThread`). Android decodes and renders the identical items, and runs a
 * tapped command back on the Mac via `menuExecuteCommand` — exactly like iOS,
 * rather than re-deriving the menu natively.
 *
 * The wire shapes below match Swift's `JSONEncoder` output verbatim (verified
 * against the encoder), including the enum-with-associated-values encoding for
 * [MenuAction] (`{"command":{"_0":{…}}}` / `{"deepLink":{"_0":"url"}}`).
 */

/** Whether a row is a tappable item or a visual separator. */
@Serializable
enum class MenuItemKind {
    @SerialName("item") ITEM,
    @SerialName("separator") SEPARATOR,
}

/** Mirrors Swift's `MenuItemRole` (only the roles a menu needs). */
@Serializable
enum class MenuItemRole {
    @SerialName("destructive") DESTRUCTIVE,
}

/** Selects which operation a `.command` action performs. */
@Serializable
enum class MenuCommandKind {
    @SerialName("projectCodeReview") PROJECT_CODE_REVIEW,
    @SerialName("projectCommitAll") PROJECT_COMMIT_ALL,
    @SerialName("projectCreatePullRequest") PROJECT_CREATE_PULL_REQUEST,
    @SerialName("projectFixCI") PROJECT_FIX_CI,
    @SerialName("threadCodeReview") THREAD_CODE_REVIEW,
    @SerialName("threadCommitFiles") THREAD_COMMIT_FILES,
    @SerialName("threadStopCodeReview") THREAD_STOP_CODE_REVIEW,
}

/**
 * A serializable description of work for the desktop to perform. `isAsync` marks
 * a command that blocks on long-running work (e.g. opening a pull request); the
 * UI shows a loading dialog and waits for it. The desktop declares the flag once
 * and every platform honors it.
 */
@Serializable
data class MenuActionCommand(
    val kind: MenuCommandKind,
    @Serializable(with = UuidSerializer::class) val projectId: UUID? = null,
    val sessionId: String? = null,
    val branch: String? = null,
    val isAsync: Boolean = false,
)

/**
 * What a tapped item does: run a named command on the Mac, or open a deep link
 * that presents platform-local UI (a sheet / setup chat) on whichever side
 * renders it. Custom-serialized to match Swift's enum encoding.
 */
@Serializable(with = MenuActionSerializer::class)
sealed interface MenuAction {
    data class Command(val command: MenuActionCommand) : MenuAction
    data class DeepLink(val url: String) : MenuAction
}

/**
 * Encodes/decodes [MenuAction] as Swift's synthesized `Codable` does for an enum
 * with a single unlabeled associated value: an object keyed by the case name,
 * whose value wraps the payload under `_0`.
 */
object MenuActionSerializer : KSerializer<MenuAction> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("MenuAction")

    override fun serialize(encoder: Encoder, value: MenuAction) {
        val json = encoder as? JsonEncoder
            ?: throw SerializationException("MenuAction can only be serialized to JSON")
        val element = when (value) {
            is MenuAction.Command -> buildJsonObject {
                put("command", buildJsonObject {
                    put("_0", json.json.encodeToJsonElement(MenuActionCommand.serializer(), value.command))
                })
            }
            is MenuAction.DeepLink -> buildJsonObject {
                put("deepLink", buildJsonObject { put("_0", JsonPrimitive(value.url)) })
            }
        }
        json.encodeJsonElement(element)
    }

    override fun deserialize(decoder: Decoder): MenuAction {
        val json = decoder as? JsonDecoder
            ?: throw SerializationException("MenuAction can only be deserialized from JSON")
        val obj: JsonObject = json.decodeJsonElement().jsonObject
        obj["command"]?.let { wrapper ->
            val inner = wrapper.jsonObject["_0"]
                ?: throw SerializationException("MenuAction.command missing _0")
            return MenuAction.Command(json.json.decodeFromJsonElement(MenuActionCommand.serializer(), inner))
        }
        obj["deepLink"]?.let { wrapper ->
            val url = wrapper.jsonObject["_0"]?.jsonPrimitive?.content
                ?: throw SerializationException("MenuAction.deepLink missing _0")
            return MenuAction.DeepLink(url)
        }
        throw SerializationException("Unknown MenuAction case: ${obj.keys}")
    }
}

/**
 * A single cross-platform menu entry. Built on the desktop, rendered on Android.
 * Optional fields are absent in the JSON when null (Swift omits nil), so the
 * defaults below reproduce the desktop's values.
 */
@Serializable
data class MenuItem(
    val id: String,
    val kind: MenuItemKind = MenuItemKind.ITEM,
    val title: String = "",
    val systemImage: String? = null,
    val role: MenuItemRole? = null,
    val isDisabled: Boolean = false,
    val action: MenuAction? = null,
    val children: List<MenuItem>? = null,
)
