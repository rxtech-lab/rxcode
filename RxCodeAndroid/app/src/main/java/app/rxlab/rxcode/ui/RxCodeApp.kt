package app.rxlab.rxcode.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.briefing.BriefingPaneScreen
import app.rxlab.rxcode.ui.onboarding.OnboardingScreen
import app.rxlab.rxcode.ui.projects.ProjectsPaneScreen
import app.rxlab.rxcode.ui.settings.SettingsScreen
import app.rxlab.rxcode.ui.sync.SyncLoadingView
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.delay

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
    if (showPairingFromSplash) {
        OnboardingScreen(state = state, viewModel = viewModel)
        return
    }
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
            activeDesktopPubkey = state.activeDesktopPubkey,
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
        return
    }

    var currentTab by rememberSaveable { mutableStateOf(RootTab.Briefing.name) }
    val tab = RootTab.valueOf(currentTab)

    // FCM notification tap: select the target session and switch to Projects
    // (where ProjectsPaneScreen reacts to `activeSessionID` and pushes the
    // chat detail). Buffered in state by MobileAppState so we route the UI
    // even if the tap arrived during the splash/onboarding gate above.
    LaunchedEffect(state.pendingNotificationSessionID) {
        val sid = state.pendingNotificationSessionID ?: return@LaunchedEffect
        viewModel.selectSession(sid)
        currentTab = RootTab.Projects.name
        viewModel.consumePendingNotificationDeepLink()
    }

    NavigationSuiteScaffold(
        navigationSuiteItems = {
            RootTab.allTabs.forEach { t ->
                item(
                    selected = t == tab,
                    onClick = { currentTab = t.name },
                    icon = { Icon(t.icon, contentDescription = null) },
                    label = { Text(t.label) },
                )
            }
        }
    ) {
        when (tab) {
            RootTab.Briefing -> BriefingPaneScreen(
                state = state,
                viewModel = viewModel,
                onOpenSession = { sid ->
                    // ProjectsPaneScreen reacts to `state.activeSessionID` and
                    // pushes the chat detail itself, so we just have to switch
                    // tabs after selecting the session.
                    viewModel.selectSession(sid)
                    currentTab = RootTab.Projects.name
                },
                onNewThread = { pid ->
                    viewModel.startNewSession(pid, planMode = false)
                    currentTab = RootTab.Projects.name
                },
            )
            RootTab.Projects -> ProjectsPaneScreen(
                state = state,
                viewModel = viewModel,
                onSettingsClick = { currentTab = RootTab.Settings.name },
            )
            RootTab.Settings -> SettingsScreen(
                state = state,
                viewModel = viewModel,
                onBack = { currentTab = RootTab.Briefing.name },
                onPairNewMac = { showPairingFromSplash = true },
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

