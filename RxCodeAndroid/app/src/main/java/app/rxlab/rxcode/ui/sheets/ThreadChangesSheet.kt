package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.rxlab.rxcode.proto.SyncFileEdit
import app.rxlab.rxcode.proto.SyncGitChange
import app.rxlab.rxcode.proto.SyncGitChangeKind
import app.rxlab.rxcode.proto.ThreadChangesResultPayload
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.chat.EditPreviewData
import app.rxlab.rxcode.ui.chat.FileDiffData
import app.rxlab.rxcode.ui.chat.additionsOnlyLines
import app.rxlab.rxcode.ui.chat.normalizedDiffLines
import app.rxlab.rxcode.ui.chat.replacementLines

/**
 * Full-screen sheet listing the changes for a thread, mirrors iOS
 * `ThreadChangesSheet`. A segmented control switches between every file
 * edited across the thread session ("This Turn") and the project's
 * uncommitted git changes ("Uncommitted"). Tapping a file opens
 * [FileDiffSheet] for the full diff.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThreadChangesSheet(
    state: MobileState,
    viewModel: MobileAppState,
    sessionId: String,
    onDismiss: () -> Unit,
) {
    var tab by remember { mutableStateOf(ChangesTab.THIS_TURN) }
    var openDiff by remember { mutableStateOf<EditPreviewData?>(null) }

    LaunchedEffect(sessionId) {
        viewModel.requestThreadChanges(sessionId)
    }

    // Only treat the cached result as "loaded" if it matches the thread the
    // sheet was opened for — mirrors iOS' staleness check.
    val result = state.threadChanges?.takeIf { it.sessionID == sessionId }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
        ),
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.surface,
        ) {
            Scaffold(
                topBar = {
                    TopAppBar(
                        title = { Text("Changes") },
                        navigationIcon = {
                            IconButton(
                                onClick = { viewModel.requestThreadChanges(sessionId) },
                                enabled = !state.isLoadingThreadChanges,
                            ) {
                                Icon(Icons.Outlined.Refresh, contentDescription = "Refresh")
                            }
                        },
                        actions = {
                            TextButton(onClick = onDismiss) { Text("Done") }
                        },
                    )
                },
            ) { padding ->
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding),
                ) {
                    SingleChoiceSegmentedButtonRow(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                    ) {
                        ChangesTab.values().forEachIndexed { index, value ->
                            SegmentedButton(
                                selected = tab == value,
                                onClick = { tab = value },
                                shape = SegmentedButtonDefaults.itemShape(
                                    index = index,
                                    count = ChangesTab.values().size,
                                ),
                            ) {
                                Text(value.label)
                            }
                        }
                    }

                    ChangesContent(
                        state = state,
                        result = result,
                        tab = tab,
                        contentPadding = PaddingValues(bottom = 16.dp),
                        onOpenEdit = { openDiff = it.toEditPreview() },
                        onOpenGit = { openDiff = it.toEditPreview() },
                        onRetry = { viewModel.requestThreadChanges(sessionId) },
                    )
                }
            }
        }
    }

    openDiff?.let { preview ->
        FileDiffSheet(
            title = preview.title,
            subtitle = preview.subtitle,
            diffs = preview.diffs,
            onDismiss = { openDiff = null },
        )
    }
}

private enum class ChangesTab(val label: String) {
    THIS_TURN("This Turn"),
    UNCOMMITTED("Uncommitted"),
}

@Composable
private fun ChangesContent(
    state: MobileState,
    result: ThreadChangesResultPayload?,
    tab: ChangesTab,
    contentPadding: PaddingValues,
    onOpenEdit: (SyncFileEdit) -> Unit,
    onOpenGit: (SyncGitChange) -> Unit,
    onRetry: () -> Unit,
) {
    when {
        result == null && !state.isPaired -> EmptyState(
            icon = Icons.Outlined.WarningAmber,
            title = "Not Connected",
            message = "Couldn't reach your Mac. Reopen the sheet once it's online.",
        )
        result == null -> LoadingState()
        else -> when (tab) {
            ChangesTab.THIS_TURN -> {
                if (result.turnEdits.isEmpty()) {
                    EmptyState(
                        icon = Icons.Outlined.CheckCircle,
                        title = "No Changes",
                        message = "No files have been edited in this thread yet.",
                    )
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = contentPadding,
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        items(result.turnEdits, key = { it.path }) { edit ->
                            FileRow(
                                badge = if (edit.containsWrite) "W" else "M",
                                badgeColor = if (edit.containsWrite) RxBlue else RxOrange,
                                name = edit.name,
                                path = edit.path,
                                stat = editStat(edit),
                                onClick = { onOpenEdit(edit) },
                            )
                        }
                    }
                }
            }
            ChangesTab.UNCOMMITTED -> {
                if (!result.ok) {
                    EmptyState(
                        icon = Icons.Outlined.WarningAmber,
                        title = "Couldn't Load Changes",
                        message = result.errorMessage ?: "Could not load changes.",
                        actionLabel = "Retry",
                        onAction = onRetry,
                    )
                } else if (result.uncommitted.isEmpty()) {
                    EmptyState(
                        icon = Icons.Outlined.CheckCircle,
                        title = "No Changes",
                        message = "No uncommitted changes.",
                    )
                } else {
                    val staged = result.uncommitted.filter { it.kind == SyncGitChangeKind.STAGED }
                    val unstaged = result.uncommitted.filter { it.kind == SyncGitChangeKind.UNSTAGED }
                    val untracked = result.uncommitted.filter { it.kind == SyncGitChangeKind.UNTRACKED }
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = contentPadding,
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        gitSection("Staged", staged, onOpenGit)
                        gitSection("Unstaged", unstaged, onOpenGit)
                        gitSection("Untracked", untracked, onOpenGit)
                    }
                }
            }
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.gitSection(
    title: String,
    changes: List<SyncGitChange>,
    onOpen: (SyncGitChange) -> Unit,
) {
    if (changes.isEmpty()) return
    item("section-$title") {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
    items(changes, key = { "${title}:${it.displayPath}" }) { change ->
        FileRow(
            badge = change.statusChar.take(1).ifEmpty { "?" },
            badgeColor = gitStatusColor(change),
            name = change.displayPath.substringAfterLast('/'),
            path = change.displayPath,
            stat = unifiedStat(change.unifiedDiff),
            onClick = { onOpen(change) },
        )
    }
}

@Composable
private fun FileRow(
    badge: String,
    badgeColor: Color,
    name: String,
    path: String,
    stat: Pair<Int, Int>,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(width = 22.dp, height = 22.dp)
                .background(badgeColor, RoundedCornerShape(5.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                badge,
                style = MaterialTheme.typography.labelSmall.copy(
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                ),
                color = Color.White,
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                name,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                path,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        val (added, removed) = stat
        if (added > 0) {
            Text(
                "+$added",
                style = MaterialTheme.typography.labelMedium.copy(
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = RxGreen,
            )
        }
        if (removed > 0) {
            Spacer(Modifier.width(2.dp))
            Text(
                "−$removed",
                style = MaterialTheme.typography.labelMedium.copy(
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = RxRed,
            )
        }
    }
}

@Composable
private fun LoadingState() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CircularProgressIndicator(modifier = Modifier.size(28.dp), strokeWidth = 2.5.dp)
            Text(
                "Loading changes…",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun EmptyState(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    message: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Box(modifier = Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                icon,
                contentDescription = null,
                modifier = Modifier.size(40.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth(),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            if (actionLabel != null && onAction != null) {
                TextButton(onClick = onAction) { Text(actionLabel) }
            }
        }
    }
}

// MARK: - Helpers

private val RxGreen = Color(0xFF2E7D32)
private val RxRed = Color(0xFFC62828)
private val RxOrange = Color(0xFFEF6C00)
private val RxBlue = Color(0xFF1565C0)
private val RxPurple = Color(0xFF6A1B9A)

private fun gitStatusColor(change: SyncGitChange): Color {
    if (change.kind == SyncGitChangeKind.UNTRACKED) return RxBlue
    return when (change.statusChar.firstOrNull()) {
        'A' -> RxGreen
        'D' -> RxRed
        'R', 'C' -> RxPurple
        else -> RxOrange
    }
}

private fun editStat(edit: SyncFileEdit): Pair<Int, Int> {
    val fromSnapshot = snapshotStat(edit.originalContent, edit.modifiedContent)
    if (fromSnapshot.first > 0 || fromSnapshot.second > 0) return fromSnapshot
    val fromHunks = edit.hunks.fold(0 to 0) { acc, hunk ->
        val removed = if (hunk.oldString.isEmpty()) 0 else hunk.oldString.split('\n').size
        val added = if (hunk.newString.isEmpty()) 0 else hunk.newString.split('\n').size
        (acc.first + added) to (acc.second + removed)
    }
    if (fromHunks.first > 0 || fromHunks.second > 0) return fromHunks
    return unifiedStat(edit.fullFileDiff.orEmpty())
}

/**
 * Coarse line-count stat for a snapshot pair. We don't have an LCS diff on
 * Android yet so the simplest accurate-enough heuristic is: if the file is
 * new (no original) every line counts as an addition; otherwise count
 * differing lines positionally and treat trailing-length deltas as
 * pure additions or removals. The detail view still falls back to the
 * unified-diff renderer for the real changes.
 */
private fun snapshotStat(original: String?, modified: String?): Pair<Int, Int> {
    if (modified == null) return 0 to 0
    if (original == null) {
        val lines = if (modified.isEmpty()) 0 else modified.split('\n').size
        return lines to 0
    }
    if (original == modified) return 0 to 0
    val oldLines = original.split('\n')
    val newLines = modified.split('\n')
    var added = 0
    var removed = 0
    val shared = minOf(oldLines.size, newLines.size)
    for (i in 0 until shared) {
        if (oldLines[i] != newLines[i]) {
            added++
            removed++
        }
    }
    if (newLines.size > oldLines.size) added += newLines.size - oldLines.size
    if (oldLines.size > newLines.size) removed += oldLines.size - newLines.size
    return added to removed
}

private fun unifiedStat(diff: String): Pair<Int, Int> {
    if (diff.isEmpty()) return 0 to 0
    var added = 0
    var removed = 0
    diff.split('\n').forEach { line ->
        when {
            line.startsWith("+") && !line.startsWith("+++") -> added++
            line.startsWith("-") && !line.startsWith("---") -> removed++
        }
    }
    return added to removed
}

private fun SyncFileEdit.toEditPreview(): EditPreviewData {
    val diffLines = when {
        !fullFileDiff.isNullOrEmpty() -> normalizedDiffLines(fullFileDiff)
        hunks.isNotEmpty() -> hunks.flatMap { replacementLines(it.oldString, it.newString) }
        !modifiedContent.isNullOrEmpty() -> additionsOnlyLines(modifiedContent)
        else -> emptyList()
    }
    return EditPreviewData(
        title = name,
        subtitle = path,
        diffs = if (diffLines.isEmpty()) emptyList() else listOf(FileDiffData(path, diffLines)),
    )
}

private fun SyncGitChange.toEditPreview(): EditPreviewData {
    val lines = if (unifiedDiff.isEmpty()) emptyList() else normalizedDiffLines(unifiedDiff)
    val name = displayPath.substringAfterLast('/')
    val subtitle = if (truncated) "$displayPath  •  diff truncated" else displayPath
    return EditPreviewData(
        title = name,
        subtitle = subtitle,
        diffs = if (lines.isEmpty()) emptyList() else listOf(FileDiffData(displayPath, lines)),
    )
}
