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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material.icons.outlined.FilterAltOff
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DividerDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.PopupProperties
import app.rxlab.rxcode.proto.Project
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.RxMarkdownText
import app.rxlab.rxcode.ui.util.rememberHaptics
import app.rxlab.rxcode.ui.util.relativeTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Briefing tab — list of per-branch briefing cards. Mirrors
 * `MobileBriefingView` on iOS: filter by project / branch, pull to refresh,
 * tap a card to drill into [BriefingDetailScreen].
 *
 * The card layout uses an adaptive 2-column grid on wider screens so tablets
 * and unfolded foldables fan out, but stays single-column on phones.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BriefingScreen(
    state: MobileState,
    viewModel: MobileAppState,
    onOpenGroup: (BriefingGroupKey) -> Unit,
    selectedGroupKey: BriefingGroupKey? = null,
) {
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()
    var selectedProjectIds by remember { mutableStateOf(emptySet<UUID>()) }
    var showAllBranches by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }

    val projectsById by remember(state.projects) {
        derivedStateOf { state.projects.associateBy { it.id } }
    }
    val activeJobsByProject by remember(state.sessions) {
        derivedStateOf {
            state.sessions.asSequence()
                .filter { it.isStreaming }
                .groupingBy { it.projectId }
                .eachCount()
        }
    }
    val allGroups by remember(state.branchBriefings, state.threadSummaries) {
        derivedStateOf { groupBriefings(state.branchBriefings, state.threadSummaries) }
    }
    val visibleGroups by remember(allGroups, selectedProjectIds, showAllBranches, state.projectBranches) {
        derivedStateOf {
            val filteredByProject = if (selectedProjectIds.isEmpty()) {
                allGroups
            } else {
                allGroups.filter { it.projectId in selectedProjectIds }
            }
            if (showAllBranches) {
                filteredByProject
            } else {
                filteredByProject.filter { group ->
                    val current = state.projectBranches[group.projectId]?.currentBranch
                        ?: return@filter true
                    group.branch == current
                }
            }
        }
    }
    val projectsWithData by remember(allGroups, state.projects) {
        derivedStateOf {
            val ids = allGroups.map { it.projectId }.toSet()
            state.projects.filter { it.id in ids }
        }
    }
    val hasAnyData = state.branchBriefings.isNotEmpty() || state.threadSummaries.isNotEmpty()
    val isFilterActive = showAllBranches || selectedProjectIds.isNotEmpty()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Briefing") },
                actions = {
                    if (hasAnyData) {
                        Box {
                            IconButton(onClick = { menuOpen = true }) {
                                Icon(
                                    if (isFilterActive) Icons.Outlined.FilterAlt else Icons.Outlined.FilterAltOff,
                                    contentDescription = "Filter",
                                )
                            }
                            BriefingFilterMenu(
                                expanded = menuOpen,
                                onDismiss = { menuOpen = false },
                                showAllBranches = showAllBranches,
                                onSetShowAllBranches = {
                                    showAllBranches = it
                                    haptics.play(HapticEvent.Selection)
                                },
                                projects = projectsWithData,
                                selectedProjectIds = selectedProjectIds,
                                onToggleProject = { id ->
                                    selectedProjectIds = if (id in selectedProjectIds) {
                                        selectedProjectIds - id
                                    } else {
                                        selectedProjectIds + id
                                    }
                                    haptics.play(HapticEvent.Selection)
                                },
                                onClearProjects = {
                                    selectedProjectIds = emptySet()
                                    haptics.play(HapticEvent.Selection)
                                },
                            )
                        }
                    }
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
            if (visibleGroups.isEmpty()) {
                BriefingEmptyState(
                    hasAnyData = hasAnyData,
                    showAllBranches = showAllBranches,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Adaptive(minSize = 320.dp),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = 16.dp, vertical = 16.dp,
                    ),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(visibleGroups, key = { it.id }) { group ->
                        BriefingCard(
                            group = group,
                            project = projectsById[group.projectId],
                            activeJobCount = activeJobsByProject[group.projectId] ?: 0,
                            isSelected = group.key == selectedGroupKey,
                            onClick = {
                                haptics.play(HapticEvent.LightTap)
                                onOpenGroup(group.key)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun BriefingCard(
    group: GroupedBriefing,
    project: Project?,
    activeJobCount: Int,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val isUnknownBranch = group.branch.equals("unknown", ignoreCase = true)
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
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.primaryContainer,
                    contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(40.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Outlined.Folder, contentDescription = null)
                    }
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        project?.name ?: "Unknown Project",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Icon(
                            Icons.Outlined.AccountTree,
                            contentDescription = null,
                            modifier = Modifier.size(12.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            if (isUnknownBranch) "Initialize Git" else group.branch,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                    }
                }
            }

            val summary = group.briefing?.briefing.orEmpty()
            if (summary.isNotEmpty()) {
                RxMarkdownText(
                    markdown = summary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 4,
                )
            } else {
                Text(
                    "No summary available yet",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.outline,
                )
            }

            HorizontalDivider(color = DividerDefaults.color.copy(alpha = 0.4f))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (activeJobCount > 0) {
                    AssistChip(
                        onClick = {},
                        enabled = false,
                        label = { Text("$activeJobCount active") },
                        leadingIcon = {
                            Box(
                                Modifier
                                    .size(8.dp)
                                    .background(
                                        MaterialTheme.colorScheme.primary,
                                        CircleShape,
                                    )
                            )
                        },
                        colors = AssistChipDefaults.assistChipColors(
                            disabledContainerColor = MaterialTheme.colorScheme.primaryContainer,
                            disabledLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            disabledLeadingIconContentColor = MaterialTheme.colorScheme.primary,
                        ),
                    )
                }
                if (group.threads.isNotEmpty()) {
                    AssistChip(
                        onClick = {},
                        enabled = false,
                        label = { Text(group.threads.size.toString()) },
                        leadingIcon = {
                            Icon(
                                Icons.Outlined.ChatBubbleOutline,
                                contentDescription = null,
                                modifier = Modifier.size(14.dp),
                            )
                        },
                    )
                }
                Spacer(Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(
                        Icons.Outlined.Schedule,
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                        tint = MaterialTheme.colorScheme.outline,
                    )
                    Text(
                        relativeTime(group.updatedAt),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
        }
    }
}

@Composable
private fun BriefingFilterMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    showAllBranches: Boolean,
    onSetShowAllBranches: (Boolean) -> Unit,
    projects: List<Project>,
    selectedProjectIds: Set<UUID>,
    onToggleProject: (UUID) -> Unit,
    onClearProjects: () -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = true),
    ) {
        Text(
            "Branches",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        DropdownMenuItem(
            text = { Text("Current branch") },
            onClick = { onSetShowAllBranches(false); onDismiss() },
            trailingIcon = { CheckIfSelected(!showAllBranches) },
        )
        DropdownMenuItem(
            text = { Text("All branches") },
            onClick = { onSetShowAllBranches(true); onDismiss() },
            trailingIcon = { CheckIfSelected(showAllBranches) },
        )
        if (projects.size > 1) {
            HorizontalDivider()
            Text(
                "Projects",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
            DropdownMenuItem(
                text = { Text("All projects") },
                onClick = { onClearProjects() },
                trailingIcon = { CheckIfSelected(selectedProjectIds.isEmpty()) },
            )
            projects.forEach { project ->
                DropdownMenuItem(
                    text = { Text(project.name) },
                    onClick = { onToggleProject(project.id) },
                    trailingIcon = { CheckIfSelected(project.id in selectedProjectIds) },
                )
            }
        }
    }
}

@Composable
private fun CheckIfSelected(selected: Boolean) {
    if (selected) {
        Icon(
            Icons.Outlined.Check,
            contentDescription = "Selected",
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
private fun BriefingEmptyState(
    hasAnyData: Boolean,
    showAllBranches: Boolean,
    modifier: Modifier = Modifier,
) {
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
                modifier = Modifier.size(72.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        if (hasAnyData) Icons.Outlined.FilterAltOff else Icons.Outlined.Description,
                        contentDescription = null,
                        modifier = Modifier.size(34.dp),
                    )
                }
            }
            Text(
                if (hasAnyData) "Nothing to Show" else "No Briefings Yet",
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                when {
                    !hasAnyData -> "Briefings appear here after threads finish on your Mac."
                    showAllBranches -> "No briefings match the selected projects."
                    else -> "No briefings for the current branch. Choose All branches to see other branches."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}
