package app.rxlab.rxcode.ui.projects

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ElevatedCard
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import app.rxlab.rxcode.proto.Project
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun ProjectsScreen(
    state: MobileState,
    onProjectClick: (Project) -> Unit,
    onSettingsClick: () -> Unit,
    selectedProjectId: java.util.UUID? = null,
    viewModel: MobileAppState? = null,
    onOpenSearch: () -> Unit = {},
) {
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Projects") },
                actions = {
                    IconButton(onClick = onOpenSearch) {
                        Icon(Icons.Outlined.Search, contentDescription = "Search")
                    }
                    IconButton(onClick = onSettingsClick) {
                        Icon(Icons.Outlined.Settings, contentDescription = "Settings")
                    }
                }
            )
        }
    ) { padding ->
        when {
            !state.hasReceivedInitialSnapshot -> Box(
                Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator()
                    Text("Waiting for your Mac…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            state.projects.isEmpty() -> Box(
                Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                EmptyProjects()
            }

            else -> PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = {
                    haptics.play(HapticEvent.LightTap)
                    refreshing = true
                    viewModel?.requestSnapshot("pull_to_refresh")
                    scope.launch {
                        delay(800)
                        refreshing = false
                    }
                },
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(state.projects, key = { it.id }) { project ->
                    val isSelected = project.id == selectedProjectId
                    val threadCount = state.sessions.count { it.projectId == project.id && !it.isArchived }
                    val activeJobCount = state.sessions.count { it.projectId == project.id && it.isStreaming }
                    val currentBranch = state.projectBranches[project.id]?.currentBranch
                    ElevatedCard(
                        modifier = Modifier
                            .fillMaxWidth(),
                        onClick = {
                            haptics.play(HapticEvent.LightTap)
                            onProjectClick(project)
                        },
                        colors = CardDefaults.elevatedCardColors(
                            containerColor = if (isSelected) {
                                MaterialTheme.colorScheme.primaryContainer
                            } else {
                                MaterialTheme.colorScheme.surfaceContainer
                            },
                        ),
                    ) {
                        Row(
                            modifier = Modifier.padding(16.dp),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.primaryContainer,
                                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.size(44.dp),
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(Icons.Outlined.Folder, contentDescription = null)
                                }
                            }
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(
                                    project.name,
                                    style = MaterialTheme.typography.titleMedium,
                                    softWrap = true,
                                )
                                Text(
                                    project.path,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    softWrap = true,
                                )
                                FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalArrangement = Arrangement.spacedBy(4.dp),
                                    modifier = Modifier.padding(top = 4.dp),
                                ) {
                                    if (!currentBranch.isNullOrBlank()) {
                                        AssistChip(
                                            onClick = {},
                                            enabled = false,
                                            label = { Text(currentBranch, softWrap = true) },
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
                                    Text(
                                        "$threadCount threads",
                                        style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.outline,
                                    )
                                    if (activeJobCount > 0) {
                                        AssistChip(
                                            onClick = {},
                                            enabled = false,
                                            label = { Text("$activeJobCount active") },
                                            leadingIcon = {
                                                Icon(
                                                    Icons.Outlined.Bolt,
                                                    contentDescription = null,
                                                    modifier = Modifier.size(14.dp),
                                                )
                                            },
                                            colors = AssistChipDefaults.assistChipColors(
                                                disabledContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                                disabledLabelColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                                disabledLeadingIconContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                            ),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                }
            }
        }
    }
}

@Composable
private fun EmptyProjects() {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.surfaceContainerHighest,
            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(64.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.Folder, contentDescription = null, modifier = Modifier.size(32.dp))
            }
        }
        Text("No projects yet", style = MaterialTheme.typography.titleMedium)
        Text("Add a project on macOS.", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
