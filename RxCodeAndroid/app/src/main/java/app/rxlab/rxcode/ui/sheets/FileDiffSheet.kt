package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.WrapText
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.ui.chat.FileDiffData

/**
 * Modal sheet that shows one or more file diffs from an edit tool call —
 * mirrors the iOS `ThreadChangeDetailView` UX: monospace lines, gutter line
 * numbers, hunk highlighting, and a wrap/scroll toggle. Used when the user
 * taps "Details" on an `EditToolCard` in the chat list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileDiffSheet(
    title: String,
    subtitle: String?,
    diffs: List<FileDiffData>,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var wrap by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                subtitle?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val (added, removed) = remember(diffs) {
                    diffs.fold(0 to 0) { acc, d ->
                        (acc.first + d.additionCount) to (acc.second + d.removalCount)
                    }
                }
                if (added > 0) DiffCountChip("+$added", Color(0xFF2E7D32))
                if (removed > 0) DiffCountChip("-$removed", Color(0xFFC62828))
                Spacer(Modifier.weight(1f))
                AssistChip(
                    onClick = { wrap = !wrap },
                    label = { Text(if (wrap) "Wrap" else "Scroll") },
                    leadingIcon = {
                        Icon(
                            if (wrap) Icons.AutoMirrored.Outlined.WrapText else Icons.Outlined.SwapHoriz,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                        )
                    },
                )
            }

            if (diffs.isEmpty()) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 120.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "No diff available",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 200.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(diffs, key = { it.path.ifEmpty { it.hashCode().toString() } }) { diff ->
                        FileDiffBlock(diff = diff, wrap = wrap)
                    }
                    item { Spacer(Modifier.height(16.dp)) }
                }
            }
        }
    }
}

@Composable
private fun DiffCountChip(label: String, color: Color) {
    Surface(
        shape = RoundedCornerShape(8.dp),
        color = color.copy(alpha = 0.14f),
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
            color = color,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}

@Composable
private fun FileDiffBlock(diff: FileDiffData, wrap: Boolean) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Column {
            if (diff.path.isNotBlank()) {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainerHighest,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        diff.path,
                        style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                }
            }
            val scrollState = rememberScrollState()
            val numbered = remember(diff.lines) { numberDiffLines(diff.lines) }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .then(if (wrap) Modifier else Modifier.horizontalScroll(scrollState))
                    .padding(vertical = 6.dp),
            ) {
                numbered.forEach { line ->
                    DiffLineRow(line, wrap = wrap)
                }
            }
        }
    }
}

@Composable
private fun DiffLineRow(line: NumberedDiffLine, wrap: Boolean) {
    val background = when (line.kind) {
        DiffLineKind.ADDITION -> Color(0xFF2E7D32).copy(alpha = 0.12f)
        DiffLineKind.REMOVAL -> Color(0xFFC62828).copy(alpha = 0.12f)
        DiffLineKind.HUNK -> MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
        DiffLineKind.CONTEXT -> Color.Transparent
    }
    val foreground = when (line.kind) {
        DiffLineKind.ADDITION -> Color(0xFF2E7D32)
        DiffLineKind.REMOVAL -> Color(0xFFC62828)
        DiffLineKind.HUNK -> MaterialTheme.colorScheme.primary
        DiffLineKind.CONTEXT -> MaterialTheme.colorScheme.onSurface
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(background)
            .padding(horizontal = 8.dp, vertical = 1.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            line.oldNumber?.toString().orEmpty(),
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(36.dp),
        )
        Text(
            line.newNumber?.toString().orEmpty(),
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(36.dp),
        )
        Text(
            line.text.ifEmpty { " " },
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            color = foreground,
            softWrap = wrap,
            modifier = Modifier.padding(start = 4.dp),
        )
    }
}

private enum class DiffLineKind { ADDITION, REMOVAL, HUNK, CONTEXT }

private data class NumberedDiffLine(
    val text: String,
    val kind: DiffLineKind,
    val oldNumber: Int?,
    val newNumber: Int?,
)

/**
 * Assigns left (original) and right (modified) gutter numbers by walking the
 * unified-diff lines. Hunk headers reset both counters by parsing their
 * `@@ -a,b +c,d @@` ranges; lines without markers (already-additions-only or
 * pure replacement output) get sequential `newNumber`s only.
 */
private fun numberDiffLines(lines: List<String>): List<NumberedDiffLine> {
    var oldCursor = 1
    var newCursor = 1
    val hunkRegex = Regex("""^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@""")
    return lines.map { raw ->
        val kind = when {
            raw.startsWith("+++") || raw.startsWith("---") -> DiffLineKind.HUNK
            raw.startsWith("@@") -> {
                hunkRegex.find(raw)?.let { match ->
                    oldCursor = match.groupValues[1].toIntOrNull() ?: oldCursor
                    newCursor = match.groupValues[2].toIntOrNull() ?: newCursor
                }
                DiffLineKind.HUNK
            }
            raw.startsWith("+") -> DiffLineKind.ADDITION
            raw.startsWith("-") -> DiffLineKind.REMOVAL
            else -> DiffLineKind.CONTEXT
        }
        when (kind) {
            DiffLineKind.HUNK -> NumberedDiffLine(raw, kind, null, null)
            DiffLineKind.ADDITION -> NumberedDiffLine(raw, kind, null, newCursor).also { newCursor++ }
            DiffLineKind.REMOVAL -> NumberedDiffLine(raw, kind, oldCursor, null).also { oldCursor++ }
            DiffLineKind.CONTEXT -> {
                val numbered = NumberedDiffLine(raw, kind, oldCursor, newCursor)
                oldCursor++
                newCursor++
                numbered
            }
        }
    }
}
