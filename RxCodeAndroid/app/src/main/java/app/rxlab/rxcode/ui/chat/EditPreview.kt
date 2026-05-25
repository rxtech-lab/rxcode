package app.rxlab.rxcode.ui.chat

import app.rxlab.rxcode.proto.ToolCall
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * Compact summary of a file-mutating tool call (edit / write / multiedit) used
 * by both the inline `EditToolCard` in the chat list and the full `FileDiffSheet`
 * presented when the user drills into an edit. Lives outside `ChatScreen.kt`
 * so the sheet can reuse the same extraction logic.
 */
data class EditPreviewData(
    val title: String,
    val subtitle: String?,
    val diffs: List<FileDiffData>,
)

data class FileDiffData(
    val path: String,
    val lines: List<String>,
) {
    val isTruncatedAtInline: Boolean get() = lines.size > 80
    fun inlineVisibleLines(): List<String> = if (isTruncatedAtInline) lines.take(80) else lines

    val additionCount: Int get() = lines.count { it.startsWith("+") && !it.startsWith("+++") }
    val removalCount: Int get() = lines.count { it.startsWith("-") && !it.startsWith("---") }
}

fun ToolCall.editPreviewData(): EditPreviewData? {
    val changes = fileChangeDiffs()
    if (changes.isNotEmpty()) {
        val title = if (changes.size == 1) {
            "Edited ${changes.first().path.substringAfterLast('/')}"
        } else {
            "Edited ${changes.size} files"
        }
        val subtitle = changes.joinToString(", ") { it.path.substringAfterLast('/') }
            .takeIf { it.isNotBlank() }
        return EditPreviewData(title = title, subtitle = subtitle, diffs = changes)
    }

    val normalized = name.normalizedToolName()
    val filePath = input.stringValue("file_path") ?: input.stringValue("path")
    val fileName = filePath?.substringAfterLast('/')?.takeIf { it.isNotBlank() }

    if (normalized == "write") {
        val content = input.stringValue("content") ?: return null
        return EditPreviewData(
            title = "Created ${fileName ?: "file"}",
            subtitle = filePath,
            diffs = listOf(FileDiffData(filePath.orEmpty(), additionsOnlyLines(content))),
        )
    }

    if (normalized == "edit") {
        val oldString = input.stringValue("old_string")
        val newString = input.stringValue("new_string")
        if (oldString != null || newString != null) {
            return EditPreviewData(
                title = "Edited ${fileName ?: "file"}",
                subtitle = filePath,
                diffs = listOf(
                    FileDiffData(
                        filePath.orEmpty(),
                        replacementLines(oldString.orEmpty(), newString.orEmpty()),
                    )
                ),
            )
        }
    }

    if (normalized == "multiedit" || normalized == "multi_edit") {
        val edits = input.arrayValue("edits")
            .mapNotNull { it as? JsonObject }
            .mapNotNull { edit ->
                val oldString = edit.stringValue("old_string")
                val newString = edit.stringValue("new_string")
                if (oldString == null && newString == null) null
                else replacementLines(oldString.orEmpty(), newString.orEmpty())
            }
        if (edits.isNotEmpty()) {
            return EditPreviewData(
                title = "Edited ${fileName ?: "file"}",
                subtitle = filePath,
                diffs = listOf(FileDiffData(filePath.orEmpty(), edits.flatten())),
            )
        }
    }

    return if (isFileModificationTool()) {
        EditPreviewData(title = displayToolName(), subtitle = filePath, diffs = emptyList())
    } else {
        null
    }
}

private fun ToolCall.fileChangeDiffs(): List<FileDiffData> {
    val directDiff = input.stringValue("diff")
    if (!directDiff.isNullOrBlank()) {
        val path = input.stringValue("path") ?: input.stringValue("file_path") ?: ""
        return listOf(FileDiffData(path, normalizedDiffLines(directDiff)))
    }

    return input.arrayValue("changes")
        .mapNotNull { it as? JsonObject }
        .mapNotNull { change ->
            val diff = change.stringValue("diff") ?: return@mapNotNull null
            val path = change.stringValue("path") ?: change.stringValue("file_path") ?: ""
            FileDiffData(path, normalizedDiffLines(diff))
        }
}

fun ToolCall.isFileModificationTool(): Boolean {
    return when (name.normalizedToolName()) {
        "edit", "write", "multiedit", "multi_edit" -> true
        else -> input.stringValue("type").equals("fileChange", ignoreCase = true) ||
            fileChangeDiffs().isNotEmpty()
    }
}

fun ToolCall.displayToolName(): String {
    return when (name.normalizedToolName()) {
        "bash", "execute" -> "Run command"
        "read" -> "Read file"
        "grep", "search" -> "Search"
        "glob" -> "Find files"
        "edit" -> "Edit file"
        "write" -> "Write file"
        "multiedit", "multi_edit" -> "Edit file"
        else -> name
    }
}

internal fun JsonObject.stringValue(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

internal fun JsonObject.arrayValue(key: String): List<JsonElement> =
    (this[key] as? JsonArray)?.toList().orEmpty()

internal fun String.normalizedToolName(): String = lowercase().replace("-", "_")

internal fun normalizedDiffLines(diff: String): List<String> {
    val rawLines = diff.split('\n')
    val hasAnyMarker = rawLines.any {
        it.startsWith("+") || it.startsWith("-") || it.startsWith("@@")
    }
    return if (hasAnyMarker) rawLines else additionsOnlyLines(diff)
}

internal fun additionsOnlyLines(content: String): List<String> =
    content.split('\n').map { if (it.isEmpty()) it else "+$it" }

internal fun replacementLines(oldString: String, newString: String): List<String> =
    oldString.split('\n').map { if (it.isEmpty()) it else "-$it" } +
        newString.split('\n').map { if (it.isEmpty()) it else "+$it" }
