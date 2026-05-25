package app.rxlab.rxcode.ui.briefing

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
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.chat.ChatScreen
import java.util.UUID

/**
 * Briefing mirrors the Projects foldable layout. The root navigation rail is
 * the first column; this screen owns the two content columns: briefing
 * list/detail on the left and selected thread messages on the right.
 */
@Suppress("UNUSED_PARAMETER")
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun BriefingPaneScreen(
    state: MobileState,
    viewModel: MobileAppState,
    onOpenSession: (String) -> Unit,
    onNewThread: (projectId: java.util.UUID) -> Unit,
) {
    BriefingContentSplitPane(
        state = state,
        viewModel = viewModel,
    )
}

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
private fun BriefingContentSplitPane(
    state: MobileState,
    viewModel: MobileAppState,
) {
    var selectedGroupKey by rememberSaveable(stateSaver = briefingGroupKeySaver) {
        mutableStateOf<BriefingGroupKey?>(null)
    }
    var selectedSessionId by rememberSaveable { mutableStateOf<String?>(null) }

    val currentKey = selectedGroupKey
    LaunchedEffect(state.branchBriefings, state.threadSummaries, currentKey) {
        if (currentKey != null) {
            val stillExists = state.branchBriefings.any {
                it.projectId == currentKey.projectId && it.branch == currentKey.branch
            } || state.threadSummaries.any {
                it.projectId == currentKey.projectId && it.branch == currentKey.branch
            }
            if (!stillExists) {
                selectedGroupKey = null
                selectedSessionId = null
            }
        }
    }

    BackHandler(enabled = selectedSessionId != null || selectedGroupKey != null) {
        when {
            selectedSessionId != null -> {
                selectedSessionId = null
                viewModel.selectSession(null)
            }
            selectedGroupKey != null -> selectedGroupKey = null
        }
    }

    val paneDirective = calculatePaneScaffoldDirectiveWithTwoPanesOnMediumWidth(
        currentWindowAdaptiveInfo(),
    )
    val shouldUseSplitLayout = paneDirective.maxHorizontalPartitions >= 2

    BoxWithConstraints(Modifier.fillMaxSize()) {
        if (shouldUseSplitLayout) {
            WideBriefingPane(
                state = state,
                viewModel = viewModel,
                selectedGroupKey = selectedGroupKey,
                onSelectGroup = {
                    selectedGroupKey = it
                    selectedSessionId = null
                    viewModel.selectSession(null)
                },
                selectedSessionId = selectedSessionId,
                onSelectSession = {
                    viewModel.selectSession(it)
                    selectedSessionId = it
                },
                onClearGroup = {
                    selectedGroupKey = null
                    selectedSessionId = null
                    viewModel.selectSession(null)
                },
                onClearSession = {
                    selectedSessionId = null
                    viewModel.selectSession(null)
                },
                availableWidth = maxWidth,
            )
            return@BoxWithConstraints
        }

        CompactBriefingPane(
            state = state,
            viewModel = viewModel,
            selectedGroupKey = selectedGroupKey,
            onSelectGroup = {
                selectedGroupKey = it
                selectedSessionId = null
                viewModel.selectSession(null)
            },
            selectedSessionId = selectedSessionId,
            onSelectSession = {
                viewModel.selectSession(it)
                selectedSessionId = it
            },
            onClearGroup = {
                selectedGroupKey = null
                selectedSessionId = null
                viewModel.selectSession(null)
            },
            onClearSession = {
                selectedSessionId = null
                viewModel.selectSession(null)
            },
        )
    }
}

@Composable
private fun CompactBriefingPane(
    state: MobileState,
    viewModel: MobileAppState,
    selectedGroupKey: BriefingGroupKey?,
    onSelectGroup: (BriefingGroupKey) -> Unit,
    selectedSessionId: String?,
    onSelectSession: (String) -> Unit,
    onClearGroup: () -> Unit,
    onClearSession: () -> Unit,
) {
    val sid = selectedSessionId
    val key = selectedGroupKey
    when {
        sid != null -> {
            ChatScreen(
                state = state,
                viewModel = viewModel,
                sessionId = sid,
                onBack = onClearSession,
            )
        }
        key != null -> {
            BriefingDetailScreen(
                state = state,
                viewModel = viewModel,
                groupKey = key,
                onBack = onClearGroup,
                onOpenSession = onSelectSession,
                onNewThread = {
                    viewModel.startNewSession(key.projectId, planMode = false)
                    state.activeSessionID?.let { onSelectSession(it) }
                },
                selectedSessionId = selectedSessionId,
            )
        }
        else -> {
            BriefingScreen(
                state = state,
                viewModel = viewModel,
                onOpenGroup = onSelectGroup,
                selectedGroupKey = selectedGroupKey,
            )
        }
    }
}

@Composable
private fun WideBriefingPane(
    state: MobileState,
    viewModel: MobileAppState,
    selectedGroupKey: BriefingGroupKey?,
    onSelectGroup: (BriefingGroupKey) -> Unit,
    selectedSessionId: String?,
    onSelectSession: (String) -> Unit,
    onClearGroup: () -> Unit,
    onClearSession: () -> Unit,
    availableWidth: Dp,
) {
    var isDetailExpanded by rememberSaveable { mutableStateOf(false) }

    BackHandler(enabled = isDetailExpanded) {
        isDetailExpanded = false
    }

    val contentWidth = (availableWidth * 0.44f).coerceIn(300.dp, 480.dp)

    Row(Modifier.fillMaxSize()) {
        if (!isDetailExpanded) {
            Box(
                modifier = Modifier
                    .width(contentWidth)
                    .fillMaxHeight(),
            ) {
                val key = selectedGroupKey
                if (key != null) {
                    BriefingDetailScreen(
                        state = state,
                        viewModel = viewModel,
                        groupKey = key,
                        onBack = onClearGroup,
                        onOpenSession = onSelectSession,
                        onNewThread = {
                            viewModel.startNewSession(key.projectId, planMode = false)
                            state.activeSessionID?.let { onSelectSession(it) }
                        },
                        selectedSessionId = selectedSessionId,
                    )
                } else {
                    BriefingScreen(
                        state = state,
                        viewModel = viewModel,
                        onOpenGroup = onSelectGroup,
                        selectedGroupKey = selectedGroupKey,
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
                    onBack = onClearSession,
                    isDetailExpanded = isDetailExpanded,
                    onToggleDetailExpanded = { isDetailExpanded = !isDetailExpanded },
                )
            } else {
                BriefingMessagePlaceholder(
                    modifier = Modifier.fillMaxSize(),
                    isDetailExpanded = isDetailExpanded,
                    onToggleDetailExpanded = { isDetailExpanded = !isDetailExpanded },
                )
            }
        }
    }
}

@Composable
private fun BriefingDetailPlaceholder(modifier: Modifier = Modifier) {
    Surface(modifier = modifier, color = MaterialTheme.colorScheme.background) {
        Box(contentAlignment = Alignment.Center) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    Icons.Outlined.Description,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(56.dp),
                )
                Text(
                    "Select a briefing",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "Tap a project on the left to view its summary and threads.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.outline,
                )
            }
        }
    }
}

@Composable
private fun BriefingMessagePlaceholder(
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
                    Icons.Outlined.Description,
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
                    "Pick a thread from the briefing to view its messages.",
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

private val briefingGroupKeySaver: Saver<BriefingGroupKey?, String> = Saver(
    save = { key -> key?.let { "${it.projectId}::${it.branch}" } ?: "" },
    restore = { raw ->
        if (raw.isEmpty()) {
            null
        } else {
            val separator = raw.indexOf("::")
            if (separator <= 0) {
                null
            } else {
                val projectId = runCatching { UUID.fromString(raw.substring(0, separator)) }.getOrNull()
                val branch = raw.substring(separator + 2)
                projectId?.let { BriefingGroupKey(it, branch) }
            }
        }
    },
)
