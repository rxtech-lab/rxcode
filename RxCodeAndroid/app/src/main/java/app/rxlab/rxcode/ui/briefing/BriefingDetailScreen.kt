package app.rxlab.rxcode.ui.briefing

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.automirrored.outlined.TextSnippet
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MobileThreadSummary
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.autopilot.ProjectActionsMenu
import app.rxlab.rxcode.ui.sheets.NewThreadSheet
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.RxMarkdownText
import app.rxlab.rxcode.ui.util.rememberHaptics
import app.rxlab.rxcode.ui.util.relativeTime

/**
 * Briefing detail screen. Mirrors `MobileBriefingDetailView` on iOS:
 * header card with project + branch + relative time, summary card with the
 * AI-generated briefing, list of threads on that branch, and a New Thread
 * extended FAB. When the branch is `"unknown"`, the header shows an
 * Initialize Git button instead of the branch chip — tapping it asks the
 * desktop to `git init` the project root.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BriefingDetailScreen(
    state: MobileState,
    viewModel: MobileAppState,
    groupKey: BriefingGroupKey,
    onBack: () -> Unit,
    onOpenSession: (String) -> Unit,
    onNewThread: (sessionId: String) -> Unit,
    selectedSessionId: String? = null,
    onOpenSearch: () -> Unit = {},
) {
    val haptics = rememberHaptics()
    val group by remember(state.branchBriefings, state.threadSummaries, groupKey) {
        derivedStateOf {
            groupBriefings(
                briefings = state.branchBriefings.filter {
                    it.projectId == groupKey.projectId && it.branch == groupKey.branch
                },
                threads = state.threadSummaries.filter {
                    it.projectId == groupKey.projectId && it.branch == groupKey.branch
                },
            ).firstOrNull()
        }
    }
    val project = remember(state.projects, groupKey.projectId) {
        state.projects.firstOrNull { it.id == groupKey.projectId }
    }
    val streamingByThread = remember(state.sessions) {
        state.sessions.associate { it.id to it.isStreaming }
    }
    val isInitializingGit = groupKey.projectId in state.pendingBranchOps
    val isUnknownBranch = groupKey.branch.equals("unknown", ignoreCase = true)
    val branchInfo = state.projectBranches[groupKey.projectId]
    var newThreadOpen by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(project?.name ?: "Briefing") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onOpenSearch) {
                        Icon(Icons.Outlined.Search, contentDescription = "Search")
                    }
                    // Autopilot / GitHub context menu, 1:1 with iOS
                    // MobileBriefingDetailView. Repo-gated like the desktop menu.
                    project?.takeIf { !it.gitHubRepo.isNullOrEmpty() }?.let { repoProject ->
                        ProjectActionsMenu(
                            project = repoProject,
                            branch = groupKey.branch,
                            branchInfo = branchInfo,
                            viewModel = viewModel,
                            onOpenSession = onOpenSession,
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
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                horizontal = 16.dp, vertical = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item("header") {
                HeaderCard(
                    projectName = project?.name ?: "Unknown Project",
                    branch = groupKey.branch,
                    isUnknownBranch = isUnknownBranch,
                    isInitializingGit = isInitializingGit,
                    updatedAt = group?.updatedAt,
                    onInitializeGit = {
                        haptics.play(HapticEvent.LightTap)
                        viewModel.initProjectGit(groupKey.projectId)
                    },
                )
            }

            item("summary") {
                SummaryCard(text = group?.briefing?.briefing.orEmpty())
            }

            item("threads-header") {
                SectionHeader(
                    icon = Icons.Outlined.ChatBubbleOutline,
                    title = "Threads",
                    count = group?.threads?.size,
                )
            }

            val threads = group?.threads.orEmpty()
            if (threads.isEmpty()) {
                item("threads-empty") { EmptyThreadsCard() }
            } else {
                items(threads, key = { it.sessionId }) { thread ->
                    ThreadRow(
                        thread = thread,
                        isStreaming = streamingByThread[thread.sessionId] == true,
                        isSelected = thread.sessionId == selectedSessionId,
                        onClick = {
                            haptics.play(HapticEvent.LightTap)
                            onOpenSession(thread.sessionId)
                        },
                    )
                }
            }
        }
    }

    if (newThreadOpen) {
        NewThreadSheet(
            viewModel = viewModel,
            projectId = groupKey.projectId,
            projectName = project?.name,
            branchInfo = branchInfo,
            preferredBranch = groupKey.branch.takeIf { !isUnknownBranch },
            onDismiss = { newThreadOpen = false },
            onSessionCreated = { sessionId ->
                newThreadOpen = false
                onNewThread(sessionId)
            },
        )
    }
}

@Composable
private fun HeaderCard(
    projectName: String,
    branch: String,
    isUnknownBranch: Boolean,
    isInitializingGit: Boolean,
    updatedAt: java.time.Instant?,
    onInitializeGit: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(52.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Folder, contentDescription = null)
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    projectName,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (isUnknownBranch) {
                        TextButton(
                            onClick = onInitializeGit,
                            enabled = !isInitializingGit,
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                                horizontal = 12.dp, vertical = 4.dp,
                            ),
                        ) {
                            if (isInitializingGit) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(14.dp),
                                    strokeWidth = 2.dp,
                                )
                                Spacer(Modifier.width(8.dp))
                                Text("Initializing…")
                            } else {
                                Icon(
                                    Icons.Outlined.Add,
                                    contentDescription = null,
                                    modifier = Modifier.size(14.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text("Initialize Git")
                            }
                        }
                    } else {
                        AssistChip(
                            onClick = {},
                            enabled = false,
                            label = { Text(branch) },
                            leadingIcon = {
                                Icon(
                                    Icons.Outlined.AccountTree,
                                    contentDescription = null,
                                    modifier = Modifier.size(14.dp),
                                )
                            },
                            colors = AssistChipDefaults.assistChipColors(
                                disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                                disabledLabelColor = MaterialTheme.colorScheme.onSurfaceVariant,
                                disabledLeadingIconContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
                        )
                    }
                    updatedAt?.let {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Icon(
                                Icons.Outlined.Schedule,
                                contentDescription = null,
                                modifier = Modifier.size(12.dp),
                                tint = MaterialTheme.colorScheme.outline,
                            )
                            Text(
                                relativeTime(it),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.outline,
                            )
                        }
                    }
                }
                if (isUnknownBranch && isInitializingGit) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun SummaryCard(text: String) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    Icons.Outlined.Description,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    "Summary",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            if (text.isNotEmpty()) {
                RxMarkdownText(
                    markdown = text,
                    style = MaterialTheme.typography.bodyMedium,
                )
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.TextSnippet,
                        contentDescription = null,
                        modifier = Modifier.size(24.dp),
                        tint = MaterialTheme.colorScheme.outline,
                    )
                    Column {
                        Text(
                            "No summary yet",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            "A summary will appear after threads complete",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.outline,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    count: Int?,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(start = 4.dp),
    ) {
        Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(14.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        if (count != null && count > 0) {
            Surface(
                shape = MaterialTheme.shapes.small,
                color = MaterialTheme.colorScheme.surfaceContainerHighest,
                modifier = Modifier.padding(start = 4.dp),
            ) {
                Text(
                    count.toString(),
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ThreadRow(
    thread: MobileThreadSummary,
    isStreaming: Boolean,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    ElevatedCard(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (isSelected) {
                MaterialTheme.colorScheme.primaryContainer
            } else {
                MaterialTheme.colorScheme.surfaceContainer
            },
        ),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    thread.title.ifBlank { "Untitled" },
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                )
                if (thread.summary.isNotEmpty()) {
                    RxMarkdownText(
                        markdown = thread.summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 3,
                    )
                }
                if (isStreaming) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier
                            .background(
                                MaterialTheme.colorScheme.primaryContainer,
                                MaterialTheme.shapes.small,
                            )
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(10.dp),
                            strokeWidth = 1.5.dp,
                        )
                        Text(
                            "Response in progress",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                        )
                    }
                } else {
                    Text(
                        relativeTime(thread.updatedAt),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
        }
    }
}

@Composable
private fun EmptyThreadsCard() {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.ChatBubbleOutline,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.outline,
                modifier = Modifier.size(28.dp),
            )
            Column {
                Text(
                    "No threads yet",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "Start a conversation from your Mac",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline,
                )
            }
        }
    }
}
