package app.rxlab.rxcode.ui.projects

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ViewSidebar
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffold
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import app.rxlab.rxcode.state.isDraftSessionId
import app.rxlab.rxcode.state.resolveSessionId
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.chat.ChatScreen
import app.rxlab.rxcode.ui.sessions.SessionsScreen
import java.util.UUID
import kotlinx.coroutines.launch

/**
 * Adaptive Projects → Sessions → Chat flow.
 *
 * - On compact widths the [ListDetailPaneScaffold] auto-collapses to one pane,
 *   recreating the iPhone push-style navigation (projects → sessions → chat
 *   back via system back).
 * - On medium / expanded widths (foldables unfolded, tablets, ChromeOS) both
 *   panes are visible. The left pane drills projects → sessions inside itself
 *   so the right pane stays on the chat — that mirrors iOS's iPad split view
 *   where the sidebar and content column live left of the chat detail.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun ProjectsPaneScreen(
    state: MobileState,
    viewModel: MobileAppState,
    onSettingsClick: () -> Unit,
    onOpenSearch: () -> Unit,
) {
    var selectedProjectId by rememberSaveable(stateSaver = uuidSaver) {
        mutableStateOf<UUID?>(null)
    }

    val paneDirective = calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth(
        currentWindowAdaptiveInfo(),
    )
    val shouldUseSplitLayout = paneDirective.maxHorizontalPartitions >= 2

    BoxWithConstraints(Modifier.fillMaxSize()) {
        if (shouldUseSplitLayout) {
            WideProjectsPane(
                state = state,
                viewModel = viewModel,
                selectedProjectId = selectedProjectId,
                onSelectProject = { selectedProjectId = it },
                onSettingsClick = onSettingsClick,
                onBackToProjects = { selectedProjectId = null },
                onOpenSearch = onOpenSearch,
                availableWidth = maxWidth,
            )
        } else {
            CollapsingProjectsPane(
                state = state,
                viewModel = viewModel,
                selectedProjectId = selectedProjectId,
                onSelectProject = { selectedProjectId = it },
                onSettingsClick = onSettingsClick,
                onBackToProjects = { selectedProjectId = null },
                onOpenSearch = onOpenSearch,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun CollapsingProjectsPane(
    state: MobileState,
    viewModel: MobileAppState,
    selectedProjectId: UUID?,
    onSelectProject: (UUID) -> Unit,
    onSettingsClick: () -> Unit,
    onBackToProjects: () -> Unit,
    onOpenSearch: () -> Unit,
) {
    val navigator = rememberListDetailPaneScaffoldNavigator<String>()
    val scope = rememberCoroutineScope()

    BackHandler(enabled = navigator.canNavigateBack() || selectedProjectId != null) {
        when {
            navigator.canNavigateBack() -> scope.launch { navigator.navigateBack() }
            selectedProjectId != null -> onBackToProjects()
        }
    }

    // React to a cross-tab navigation (Briefing → thread). When activeSessionID
    // changes from outside this scaffold, locate its owning project, drill the
    // list pane into that project's sessions, and push the chat detail pane.
    // Skip draft ids: `startNewSession` flips activeSessionID to a draft id
    // before the desktop has assigned a real session, and the new-thread sheet
    // already owns navigation for that flow once the real session lands.
    LaunchedEffect(state.activeSessionID, state.sessions) {
        val sid = state.activeSessionID ?: return@LaunchedEffect
        if (isDraftSessionId(sid)) return@LaunchedEffect
        val resolved = state.resolveSessionId(sid)
        val pid = state.sessions.firstOrNull { it.id == resolved || it.id == sid }?.projectId
        if (pid != null && selectedProjectId != pid) {
            onSelectProject(pid)
        }
        val detailContent = navigator.currentDestination?.content
        if (detailContent != sid) {
            navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, sid)
        }
    }

    ListDetailPaneScaffold(
        directive = navigator.scaffoldDirective,
        value = navigator.scaffoldValue,
        listPane = {
            AnimatedPane {
                val pid = selectedProjectId
                if (pid == null) {
                    ProjectsScreen(
                        state = state,
                        onProjectClick = { project -> onSelectProject(project.id) },
                        onSettingsClick = onSettingsClick,
                        viewModel = viewModel,
                        onOpenSearch = onOpenSearch,
                    )
                } else {
                    SessionsScreen(
                        state = state,
                        projectId = pid,
                        onSessionClick = { session ->
                            viewModel.selectSession(session.id)
                            scope.launch {
                                navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, session.id)
                            }
                        },
                        onNewThread = { sessionId ->
                            viewModel.selectSession(sessionId)
                            scope.launch {
                                navigator.navigateTo(ListDetailPaneScaffoldRole.Detail, sessionId)
                            }
                        },
                        onBack = onBackToProjects,
                        viewModel = viewModel,
                        onOpenSearch = onOpenSearch,
                    )
                }
            }
        },
        detailPane = {
            AnimatedPane {
                val sid = navigator.currentDestination?.content
                if (sid != null) {
                    ChatScreen(
                        state = state,
                        viewModel = viewModel,
                        sessionId = sid,
                        onBack = {
                            viewModel.selectSession(null)
                            scope.launch { navigator.navigateBack() }
                        },
                    )
                } else {
                    ChatPlaceholder(modifier = Modifier.fillMaxSize())
                }
            }
        },
    )
}

@Composable
private fun WideProjectsPane(
    state: MobileState,
    viewModel: MobileAppState,
    selectedProjectId: UUID?,
    onSelectProject: (UUID) -> Unit,
    onSettingsClick: () -> Unit,
    onBackToProjects: () -> Unit,
    onOpenSearch: () -> Unit,
    availableWidth: Dp,
) {
    var selectedSessionId by rememberSaveable { mutableStateOf<String?>(null) }
    var isDetailExpanded by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(state.activeSessionID, state.sessions) {
        val sid = state.activeSessionID ?: return@LaunchedEffect
        if (isDraftSessionId(sid)) return@LaunchedEffect
        val resolved = state.resolveSessionId(sid)
        val pid = state.sessions.firstOrNull { it.id == resolved || it.id == sid }?.projectId
        if (pid != null && selectedProjectId != pid) {
            onSelectProject(pid)
        }
        selectedSessionId = sid
    }

    BackHandler(enabled = isDetailExpanded || selectedSessionId != null || selectedProjectId != null) {
        when {
            isDetailExpanded -> isDetailExpanded = false
            selectedSessionId != null -> {
                selectedSessionId = null
                viewModel.selectSession(null)
            }
            selectedProjectId != null -> onBackToProjects()
        }
    }

    val contentWidth = (availableWidth * 0.42f).coerceIn(300.dp, 460.dp)

    Row(Modifier.fillMaxSize()) {
        if (!isDetailExpanded) {
            Box(
                modifier = Modifier
                    .width(contentWidth)
                    .fillMaxHeight(),
            ) {
                val pid = selectedProjectId
                if (pid == null) {
                    ProjectsScreen(
                        state = state,
                        onProjectClick = { project ->
                            onSelectProject(project.id)
                            selectedSessionId = null
                            viewModel.selectSession(null)
                        },
                        onSettingsClick = onSettingsClick,
                        viewModel = viewModel,
                        onOpenSearch = onOpenSearch,
                    )
                } else {
                    SessionsScreen(
                        state = state,
                        projectId = pid,
                        onSessionClick = { session ->
                            viewModel.selectSession(session.id)
                            selectedSessionId = session.id
                        },
                        onNewThread = { sessionId ->
                            viewModel.selectSession(sessionId)
                            selectedSessionId = sessionId
                        },
                        onBack = onBackToProjects,
                        viewModel = viewModel,
                        selectedSessionId = selectedSessionId,
                        onOpenSearch = onOpenSearch,
                    )
                }
            }
            VerticalDivider()
        }
        Box(Modifier.weight(1f).fillMaxHeight()) {
            val sid = selectedSessionId
            if (sid != null) {
                ChatScreen(
                    state = state,
                    viewModel = viewModel,
                    sessionId = sid,
                    onBack = {
                        selectedSessionId = null
                        viewModel.selectSession(null)
                    },
                    isDetailExpanded = isDetailExpanded,
                    onToggleDetailExpanded = { isDetailExpanded = !isDetailExpanded },
                )
            } else {
                ChatPlaceholder(
                    modifier = Modifier.fillMaxSize(),
                    isDetailExpanded = isDetailExpanded,
                    onToggleDetailExpanded = { isDetailExpanded = !isDetailExpanded },
                )
            }
        }
    }
}

@Composable
private fun ProjectContentPlaceholder(modifier: Modifier = Modifier) {
    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        Box(contentAlignment = Alignment.Center) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    Icons.Outlined.ChatBubbleOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(56.dp),
                )
                Text(
                    "Select a project",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "Pick a project from the sidebar to see its threads.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.outline,
                )
            }
        }
    }
}

@Composable
private fun ChatPlaceholder(
    modifier: Modifier = Modifier,
    isDetailExpanded: Boolean? = null,
    onToggleDetailExpanded: (() -> Unit)? = null,
) {
    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        Box(contentAlignment = Alignment.Center) {
            if (isDetailExpanded != null && onToggleDetailExpanded != null) {
                IconButton(
                    onClick = onToggleDetailExpanded,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(8.dp),
                ) {
                    Icon(
                        Icons.AutoMirrored.Outlined.ViewSidebar,
                        contentDescription = if (isDetailExpanded) "Show content column" else "Collapse content column",
                    )
                }
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    Icons.Outlined.ChatBubbleOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(56.dp),
                )
                Text(
                    "Select a thread",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "Pick a thread in the content column, or start a new one.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.outline,
                )
            }
        }
    }
}

private fun Dp.coerceIn(minimumValue: Dp, maximumValue: Dp): Dp {
    return when {
        this < minimumValue -> minimumValue
        this > maximumValue -> maximumValue
        else -> this
    }
}

private val uuidSaver: Saver<UUID?, String> = Saver(
    save = { it?.toString() ?: "" },
    restore = { if (it.isEmpty()) null else UUID.fromString(it) },
)

