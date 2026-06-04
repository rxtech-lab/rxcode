package app.rxlab.rxcode.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.state.PairingStatus
import app.rxlab.rxcode.ui.briefing.BriefingPaneScreen
import app.rxlab.rxcode.ui.onboarding.OnboardingScreen
import app.rxlab.rxcode.ui.projects.ProjectsPaneScreen
import app.rxlab.rxcode.ui.search.SearchScreen
import app.rxlab.rxcode.ui.settings.SettingsScreen
import app.rxlab.rxcode.ui.sync.SyncLoadingView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay

private const val MaxRootTabHistory = 8

/**
 * Root composable. Adapts top-level navigation to window class via
 * [NavigationSuiteScaffold]: bottom NavigationBar on a phone, NavigationRail
 * once we have enough horizontal room (foldable open, tablet portrait),
 * NavigationDrawer on really wide screens (tablet landscape / desktop).
 *
 * Each content tab is itself adaptive: Briefing and Projects use
 * `ListDetailPaneScaffold` internally so a wide screen shows two panes
 * (list + detail) automatically, and a phone collapses to a single pane the
 * back gesture pops between.
 */
@Composable
fun RxCodeApp(state: MobileState, viewModel: MobileAppState) {
    if (!state.isPaired) {
        OnboardingScreen(state = state, viewModel = viewModel)
        return
    }

    // Splash gate: show SyncLoadingView until the first snapshot lands. After
    // ~15 seconds without a snapshot we flip into the timed-out state so the
    // user can retry, switch desktops, or pair a new Mac.
    var showPairingFromSplash by rememberSaveable { mutableStateOf(false) }
    if (!state.hasReceivedInitialSnapshot) {
        var timedOut by rememberSaveable { mutableStateOf(false) }
        LaunchedEffect(state.hasReceivedInitialSnapshot, state.activeDesktopPubkey) {
            if (!state.hasReceivedInitialSnapshot && !timedOut) {
                delay(15_000)
                if (!state.hasReceivedInitialSnapshot) timedOut = true
            }
        }
        SyncLoadingView(
            isTimedOut = timedOut,
            pairedDesktops = state.pairedDesktops,
            activeDesktopId = state.activeDesktopId,
            onRetry = {
                timedOut = false
                viewModel.requestSnapshot("user_retry")
            },
            onSelectDesktop = { desktop ->
                timedOut = false
                viewModel.switchActiveDesktop(desktop)
            },
            onPairNewDesktop = { showPairingFromSplash = true },
        )
        if (showPairingFromSplash) {
            PairingDialog(
                state = state,
                viewModel = viewModel,
                onDismiss = { showPairingFromSplash = false },
            )
        }
        return
    }

    var rootTabHistory by rememberSaveable { mutableStateOf(listOf(RootTab.Briefing.name)) }
    val tab = RootTab.valueOf(rootTabHistory.lastOrNull() ?: RootTab.Briefing.name)
    val tabStateHolder = rememberSaveableStateHolder()

    fun navigateToTab(destination: RootTab) {
        if (tab == destination) return
        rootTabHistory = (rootTabHistory + destination.name).takeLast(MaxRootTabHistory)
    }

    fun navigateRootBack() {
        rootTabHistory = if (rootTabHistory.size > 1) {
            rootTabHistory.dropLast(1)
        } else {
            listOf(RootTab.Briefing.name)
        }
    }

    BackHandler(enabled = rootTabHistory.size > 1) {
        navigateRootBack()
    }

    // Global search is presented as a full-screen overlay rather than a tab —
    // every list/detail screen surfaces a toolbar search button that flips this
    // (mirrors iOS, where search lives in the toolbar, not the tab bar).
    var showSearch by rememberSaveable { mutableStateOf(false) }
    val openSearch = { showSearch = true }

    // FCM notification tap: select the target session and switch to Projects
    // (where ProjectsPaneScreen reacts to `activeSessionID` and pushes the
    // chat detail). Buffered in state by MobileAppState so we route the UI
    // even if the tap arrived during the splash/onboarding gate above.
    LaunchedEffect(state.pendingNotificationSessionID) {
        val sid = state.pendingNotificationSessionID ?: return@LaunchedEffect
        viewModel.selectSession(sid)
        navigateToTab(RootTab.Projects)
        viewModel.consumePendingNotificationDeepLink()
    }

    Box(Modifier.fillMaxSize()) {
        NavigationSuiteScaffold(
            navigationSuiteItems = {
                RootTab.allTabs.forEach { t ->
                    item(
                        selected = t == tab,
                        onClick = { navigateToTab(t) },
                        icon = { Icon(t.icon, contentDescription = null) },
                        label = { Text(t.label) },
                    )
                }
            }
        ) {
            tabStateHolder.SaveableStateProvider(tab.name) {
                when (tab) {
                    RootTab.Briefing -> BriefingPaneScreen(
                        state = state,
                        viewModel = viewModel,
                        onOpenSession = { sid ->
                            // ProjectsPaneScreen reacts to `state.activeSessionID` and
                            // pushes the chat detail itself, so we just have to switch
                            // tabs after selecting the session.
                            viewModel.selectSession(sid)
                            navigateToTab(RootTab.Projects)
                        },
                        onNewThread = { pid ->
                            viewModel.startNewSession(pid, planMode = false)
                            navigateToTab(RootTab.Projects)
                        },
                        onOpenSearch = openSearch,
                    )
                    RootTab.Projects -> ProjectsPaneScreen(
                        state = state,
                        viewModel = viewModel,
                        onSettingsClick = { navigateToTab(RootTab.Settings) },
                        onOpenSearch = openSearch,
                    )
                    RootTab.Settings -> SettingsScreen(
                        state = state,
                        viewModel = viewModel,
                        onBack = { navigateRootBack() },
                        onPairNewMac = { showPairingFromSplash = true },
                        onOpenSearch = openSearch,
                    )
                }
            }
        }

        if (showSearch) {
            Surface(Modifier.fillMaxSize()) {
                SearchScreen(
                    state = state,
                    viewModel = viewModel,
                    onOpenSession = { sid ->
                        viewModel.selectSession(sid)
                        navigateToTab(RootTab.Projects)
                        showSearch = false
                    },
                    onClose = {
                        showSearch = false
                        viewModel.clearSearch()
                    },
                )
            }
        }

        if (showPairingFromSplash) {
            PairingDialog(
                state = state,
                viewModel = viewModel,
                onDismiss = { showPairingFromSplash = false },
            )
        }
    }
}

@Composable
private fun PairingDialog(
    state: MobileState,
    viewModel: MobileAppState,
    onDismiss: () -> Unit,
) {
    var sawPairingInProgress by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state.pairing) {
        if (state.pairing == PairingStatus.InProgress) {
            sawPairingInProgress = true
        } else if (sawPairingInProgress && state.pairing == PairingStatus.Idle) {
            onDismiss()
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Surface(Modifier.fillMaxSize()) {
            OnboardingScreen(
                state = state,
                viewModel = viewModel,
                onDismiss = onDismiss,
            )
        }
    }
}

enum class RootTab(
    val label: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
) {
    Briefing("Briefing", Icons.Outlined.Description),
    Projects("Projects", Icons.Outlined.Folder),
    Settings("Settings", Icons.Outlined.Settings);

    companion object {
        val allTabs: List<RootTab> = listOf(Briefing, Projects, Settings)
    }
}
