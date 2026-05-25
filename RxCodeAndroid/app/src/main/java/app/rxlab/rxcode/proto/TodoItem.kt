package app.rxlab.rxcode.proto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

@Serializable
data class TodoItem(
    val id: Int,
    val content: String,
    val activeForm: String,
    val status: Status,
) {
    @Serializable
    enum class Status {
        @SerialName("pending") PENDING,
        @SerialName("in_progress") IN_PROGRESS,
        @SerialName("completed") COMPLETED,
    }
}

/**
 * Locates the most recent `TodoWrite` tool call across the message list and
 * parses its `todos` array into typed [TodoItem]s. Mirrors the iOS
 * `TodoExtractor.latest` so the navigation-title progress ring and the
 * todo/summary sheet reflect the same data the desktop sees.
 */
object TodoExtractor {
    fun latest(messages: List<ChatMessage>): List<TodoItem>? {
        for (message in messages.asReversed()) {
            for (block in message.blocks.asReversed()) {
                val toolCall = block.toolCall ?: continue
                if (toolCall.name.equals("TodoWrite", ignoreCase = true)) {
                    return parse(toolCall.input)
                }
            }
        }
        return null
    }

    fun parse(input: JsonObject): List<TodoItem> {
        val array = input["todos"] as? JsonArray ?: return emptyList()
        return array.mapIndexedNotNull { index, element ->
            val obj = element as? JsonObject ?: return@mapIndexedNotNull null
            val content = obj.string("content").orEmpty()
            val activeForm = obj.string("activeForm").takeIf { !it.isNullOrEmpty() } ?: content
            val status = when (obj.string("status")) {
                "in_progress" -> TodoItem.Status.IN_PROGRESS
                "completed" -> TodoItem.Status.COMPLETED
                else -> TodoItem.Status.PENDING
            }
            TodoItem(id = index, content = content, activeForm = activeForm, status = status)
        }
    }

    private fun JsonObject.string(key: String): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull
}
