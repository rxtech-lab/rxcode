package app.rxlab.rxcode.ui.sessions

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DriveFileRenameOutline
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MenuAction
import app.rxlab.rxcode.proto.MenuCommandKind
import app.rxlab.rxcode.proto.MenuItem
import app.rxlab.rxcode.proto.SessionAttentionKind
import app.rxlab.rxcode.proto.SessionSummary
import app.rxlab.rxcode.proto.TodoItem
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.autopilot.ProjectActionsMenu
import app.rxlab.rxcode.ui.autopilot.commandLoadingText
import app.rxlab.rxcode.ui.autopilot.SerializedMenuItems
import app.rxlab.rxcode.ui.sheets.NewThreadSheet
import app.rxlab.rxcode.ui.sheets.RenameThreadSheet
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics
import app.rxlab.rxcode.ui.util.relativeTime
import java.util.UUID

/**
 * Thread list for one project. Mirrors `SessionsList` on iOS — each row shows
 * the title, a relative-time stamp, a branch chip when a branch is recorded
 * on the session's owning project, plus streaming / attention chips.
 *
 * Long-pressing the overflow icon opens a dropdown menu for rename, archive,
 * and delete; rename pops a [RenameThreadSheet]. The FAB triggers a
 * [NewThreadSheet] populated with the project's current/available branches.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionsScreen(
    state: MobileState,
    projectId: UUID,
    onSessionClick: (SessionSummary) -> Unit,
    onNewThread: (sessionId: String) -> Unit,
    onBack: () -> Unit,
    viewModel: MobileAppState,
    selectedSessionId: String? = null,
    onOpenSearch: () -> Unit = {},
) {
    val haptics = rememberHaptics()
    val project = state.projects.firstOrNull { it.id == projectId }
    val sessions = remember(state.sessions, projectId) {
        state.sessions.filter { it.projectId == projectId && !it.isArchived }
    }
    // Split into top-level threads and their nested review children. A review
    // child (`parentThreadId` set) nests under its parent when that parent is in
    // this list; an orphan child falls back to the top level so it's never hidden.
    val sessionIds = remember(sessions) { sessions.map { it.id }.toSet() }
    val topLevel = remember(sessions, sessionIds) {
        sessions.filter { it.parentThreadId == null || it.parentThreadId !in sessionIds }
    }
    val childrenByParent = remember(sessions, sessionIds) {
        sessions
            .filter { it.parentThreadId != null && it.parentThreadId in sessionIds }
            .groupBy { it.parentThreadId!! }
            .mapValues { (_, group) -> group.sortedBy { it.updatedAt } }
    }
    var expandedParentIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    val branchInfo = state.projectBranches[projectId]
    var newThreadOpen by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<SessionSummary?>(null) }
    var deleteTarget by remember { mutableStateOf<SessionSummary?>(null) }
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(project?.name ?: "Threads") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onOpenSearch) {
                        Icon(Icons.Outlined.Search, contentDescription = "Search")
                    }
                    // Project-level context menu (autopilot actions + Delete
                    // Project), 1:1 with iOS SessionsList. The per-thread row
                    // menu (rename/archive/delete) stays on each card below.
                    project?.let { proj ->
                        ProjectActionsMenu(
                            project = proj,
                            branch = branchInfo?.currentBranch,
                            branchInfo = branchInfo,
                            viewModel = viewModel,
                            prNumber = state.ciStatusByProject[projectId]?.prNumber,
                            includeDeleteProject = true,
                            onOpenSession = onNewThread,
                            onProjectDeleted = onBack,
                        )
                    }
                },
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                text = { Text("New thread") },
                icon = { Icon(Icons.Outlined.Add, contentDescription = null) },
                onClick = {
                    haptics.play(HapticEvent.LightTap)
                    newThreadOpen = true
                },
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                haptics.play(HapticEvent.LightTap)
                refreshing = true
                viewModel.requestSnapshot("pull_to_refresh")
                scope.launch {
                    delay(800)
                    refreshing = false
                }
            },
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            if (sessions.isEmpty()) {
                EmptySessionsState(modifier = Modifier.fillMaxSize())
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = 16.dp, vertical = 12.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    topLevel.forEach { parent ->
                        val children = childrenByParent[parent.id].orEmpty()
                        val expanded = parent.id in expandedParentIds
                        item(key = parent.id) {
                            SessionCard(
                                session = parent,
                                isSelected = parent.id == selectedSessionId,
                                onClick = {
                                    haptics.play(HapticEvent.LightTap)
                                    onSessionClick(parent)
                                },
                                onRename = { renameTarget = parent },
                                onArchive = {
                                    haptics.play(HapticEvent.HeavyImpact)
                                    viewModel.archiveThread(parent.id)
                                },
                                onDelete = { deleteTarget = parent },
                                viewModel = viewModel,
                                onOpenThread = onNewThread,
                                reviewCount = children.size,
                                isExpanded = expanded,
                                isReviewing = children.any { it.isStreaming },
                                onToggleReviews = if (children.isEmpty()) {
                                    null
                                } else {
                                    {
                                        expandedParentIds = if (expanded) {
                                            expandedParentIds - parent.id
                                        } else {
                                            expandedParentIds + parent.id
                                        }
                                    }
                                },
                            )
                        }
                        if (expanded) {
                            itemsIndexed(children, key = { _, child -> child.id }) { index, child ->
                                SessionCard(
                                    session = child,
                                    isSelected = child.id == selectedSessionId,
                                    onClick = {
                                        haptics.play(HapticEvent.LightTap)
                                        onSessionClick(child)
                                    },
                                    onRename = { renameTarget = child },
                                    onArchive = {
                                        haptics.play(HapticEvent.HeavyImpact)
                                        viewModel.archiveThread(child.id)
                                    },
                                    onDelete = { deleteTarget = child },
                                    viewModel = viewModel,
                                    onOpenThread = onNewThread,
                                    indentLevel = 1,
                                    titleOverride = "Review ${index + 1}",
                                    showLabel = false,
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    if (newThreadOpen) {
        NewThreadSheet(
            viewModel = viewModel,
            projectId = projectId,
            projectName = project?.name,
            branchInfo = branchInfo,
            onDismiss = { newThreadOpen = false },
            onSessionCreated = { sessionId ->
                newThreadOpen = false
                onNewThread(sessionId)
            },
        )
    }

    renameTarget?.let { target ->
        RenameThreadSheet(
            currentTitle = target.title,
            onDismiss = { renameTarget = null },
            onSubmit = { newTitle ->
                viewModel.renameThread(target.id, newTitle)
                renameTarget = null
            },
        )
    }

    deleteTarget?.let { target ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { deleteTarget = null },
            icon = { Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
            title = { Text("Delete thread?") },
            text = {
                Text(
                    "This permanently removes \"${target.title.ifBlank { "Untitled" }}\" and its messages from both your Mac and this device.",
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = {
                    haptics.play(HapticEvent.HeavyImpact)
                    viewModel.deleteThread(target.id)
                    deleteTarget = null
                }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { deleteTarget = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun EmptySessionsState(modifier: Modifier = Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(24.dp),
        ) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surfaceContainerHighest,
                contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(64.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        Icons.Outlined.ChatBubbleOutline,
                        contentDescription = null,
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
            Text("No threads yet", style = MaterialTheme.typography.titleMedium)
            Text(
                "Tap New thread to start a conversation.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * Thread row mirroring iOS `GlassThreadCard`. Shows a status dot, the title,
 * relative updated time, optional todo progress, and a streaming indicator
 * when the thread is actively running.
 */
@Composable
private fun SessionCard(
    session: SessionSummary,
    isSelected: Boolean,
    onClick: () -> Unit,
    onRename: () -> Unit,
    onArchive: () -> Unit,
    onDelete: () -> Unit,
    viewModel: MobileAppState,
    onOpenThread: (String) -> Unit = {},
    reviewCount: Int = 0,
    isExpanded: Boolean = false,
    isReviewing: Boolean = false,
    onToggleReviews: (() -> Unit)? = null,
    indentLevel: Int = 0,
    titleOverride: String? = null,
    showLabel: Boolean = true,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val cardScope = rememberCoroutineScope()
    // The desktop-mediated thread actions (Code Review / Commit Files / Stop) come
    // from the Mac as the same serialized menu it renders — fetched lazily and
    // re-keyed on the gating state so it refreshes after edits / a review starts.
    // Rename / Archive / Delete below are Android-local.
    var threadMenu by remember(session.id) { mutableStateOf<List<MenuItem>?>(null) }
    LaunchedEffect(session.id, session.hasRecordedFileChanges, isReviewing) {
        threadMenu = runCatching { viewModel.fetchThreadMenu(session.id) }.getOrNull()
    }

    // Drives the loading dialog while an async thread command (e.g. a custom API
    // call) runs; `dispatchingThreadCommand` guards re-entrancy and `threadCommandError`
    // surfaces a failure to the user instead of silently swallowing it. Mirrors
    // `ProjectActionsMenu`.
    var dispatchingThreadCommand by remember { mutableStateOf(false) }
    var asyncThreadCommand by remember { mutableStateOf<MenuCommandKind?>(null) }
    var threadCommandError by remember { mutableStateOf<String?>(null) }
    fun runThreadAction(action: MenuAction?) {
        val command = (action as? MenuAction.Command)?.command ?: return
        if (dispatchingThreadCommand) return
        menuOpen = false
        dispatchingThreadCommand = true
        if (command.isAsync) asyncThreadCommand = command.kind
        cardScope.launch {
            try {
                val result = viewModel.executeMenuCommand(command)
                viewModel.requestSnapshot("menu_command")
                result.threadId?.let { onOpenThread(it) }
            } catch (t: Throwable) {
                threadCommandError = t.message ?: "Couldn't complete the action."
            } finally {
                dispatchingThreadCommand = false
                asyncThreadCommand = null
            }
        }
    }

    asyncThreadCommand?.let { kind ->
        val (title, message) = commandLoadingText(kind)
        AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            title = { Text(title) },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                    Text(message)
                }
            },
        )
    }
    threadCommandError?.let { message ->
        AlertDialog(
            onDismissRequest = { threadCommandError = null },
            title = { Text("Couldn't Complete") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { threadCommandError = null }) { Text("OK") } },
        )
    }
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = (indentLevel * 24).dp),
        onClick = onClick,
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (isSelected) {
                MaterialTheme.colorScheme.primaryContainer
            } else {
                MaterialTheme.colorScheme.surfaceContainer
            },
        ),
    ) {
        Row(
            Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Disclosure control for a thread that has nested review children;
            // tapping it toggles expansion (separate from the card's onClick).
            if (onToggleReviews != null) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(1.dp),
                    modifier = Modifier
                        .clickable { onToggleReviews() }
                        .padding(2.dp),
                ) {
                    Icon(
                        if (isExpanded) Icons.Outlined.KeyboardArrowDown else Icons.AutoMirrored.Outlined.KeyboardArrowRight,
                        contentDescription = if (isExpanded) "Hide code reviews" else "Show code reviews",
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (isReviewing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(10.dp),
                            strokeWidth = 1.5.dp,
                        )
                    } else {
                        Text(
                            "$reviewCount",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            StatusDot(session)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    titleOverride ?: session.title.ifBlank { "Untitled" },
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                )
                session.threadLabel?.takeIf { showLabel && it.isNotBlank() }?.let { label ->
                    Surface(
                        shape = MaterialTheme.shapes.small,
                        color = MaterialTheme.colorScheme.primaryContainer,
                    ) {
                        Text(
                            label,
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    UpdatedTimeLabel(session)
                    session.todos?.takeIf { it.isNotEmpty() }?.let { TodoProgressLabel(it) }
                }
            }
            if (session.isStreaming) {
                StreamingDots()
            }
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Outlined.MoreVert, contentDescription = "More")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    // Desktop-built thread actions (Code Review / Commit Files / Stop
                    // Code Review), gated by the Mac. Empty for a `[Code Review]`
                    // thread, which the desktop excludes.
                    threadMenu?.takeIf { it.isNotEmpty() }?.let { items ->
                        SerializedMenuItems(items, onAction = ::runThreadAction)
                        HorizontalDivider()
                    }
                    DropdownMenuItem(
                        text = { Text("Rename") },
                        leadingIcon = { Icon(Icons.Outlined.DriveFileRenameOutline, contentDescription = null) },
                        onClick = { menuOpen = false; onRename() },
                    )
                    DropdownMenuItem(
                        text = { Text("Archive") },
                        leadingIcon = { Icon(Icons.Outlined.Archive, contentDescription = null) },
                        onClick = { menuOpen = false; onArchive() },
                    )
                    DropdownMenuItem(
                        text = { Text("Delete") },
                        leadingIcon = {
                            Icon(
                                Icons.Outlined.Delete,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                            )
                        },
                        onClick = { menuOpen = false; onDelete() },
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusDot(session: SessionSummary) {
    val color = when {
        session.attention == SessionAttentionKind.QUESTION -> Color(0xFFEAB308)
        session.attention == SessionAttentionKind.PERMISSION -> Color(0xFFF97316)
        session.hasUncheckedCompletion && !session.isStreaming -> Color(0xFF22C55E)
        else -> null
    } ?: return
    Surface(
        shape = CircleShape,
        color = color,
        modifier = Modifier.size(10.dp),
    ) {}
}

@Composable
private fun UpdatedTimeLabel(session: SessionSummary) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            Icons.Outlined.Schedule,
            contentDescription = null,
            modifier = Modifier.size(12.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            relativeTime(session.updatedAt),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun TodoProgressLabel(todos: List<TodoItem>) {
    val completed = todos.count { it.status == TodoItem.Status.COMPLETED }
    val total = todos.size
    val allDone = completed == total
    val inProgress = todos.any { it.status == TodoItem.Status.IN_PROGRESS }
    val tint = if (allDone) Color(0xFF22C55E) else MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        when {
            inProgress -> CircularProgressIndicator(
                modifier = Modifier.size(11.dp),
                strokeWidth = 1.5.dp,
                color = tint,
            )
            allDone -> Icon(
                Icons.Outlined.CheckCircle,
                contentDescription = null,
                modifier = Modifier.size(12.dp),
                tint = tint,
            )
            else -> Icon(
                Icons.Outlined.RadioButtonUnchecked,
                contentDescription = null,
                modifier = Modifier.size(12.dp),
                tint = tint,
            )
        }
        Text(
            "$completed/$total",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.Medium,
            color = tint,
        )
    }
}

@Composable
private fun StreamingDots() {
    val transition = rememberInfiniteTransition(label = "streaming-dots")
    val color = MaterialTheme.colorScheme.primary
    Row(
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .padding(horizontal = 4.dp),
    ) {
        repeat(3) { index ->
            val alpha by transition.animateFloat(
                initialValue = 0.4f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    animation = tween(durationMillis = 400, delayMillis = index * 120),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "streaming-dot-$index",
            )
            Surface(
                shape = CircleShape,
                color = color.copy(alpha = alpha),
                modifier = Modifier.size(6.dp),
            ) {}
        }
    }
}
