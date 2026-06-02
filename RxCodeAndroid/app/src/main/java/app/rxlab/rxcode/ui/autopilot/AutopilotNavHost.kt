package app.rxlab.rxcode.ui.autopilot

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import app.rxlab.rxcode.proto.DocsRepo
import app.rxlab.rxcode.proto.ReleaseRepo
import app.rxlab.rxcode.proto.SecretsEnvironment
import app.rxlab.rxcode.proto.WatchedRepo
import app.rxlab.rxcode.state.MobileAppState

/**
 * Destinations inside the Autopilot feature. Modeled as a tiny in-memory back
 * stack (not the global NavHost) so detail screens can carry already-fetched
 * model objects, mirroring iOS `NavigationStack` value-typed destinations.
 */
sealed interface AutopilotRoute {
    data object Hub : AutopilotRoute
    data object Automation : AutopilotRoute
    data object RepoSetup : AutopilotRoute
    data object Secrets : AutopilotRoute
    data class SecretsRepo(val repo: String) : AutopilotRoute
    data class SecretsEnv(val repo: String, val env: SecretsEnvironment) : AutopilotRoute
    data object Ci : AutopilotRoute
    data class CiRepo(val repo: WatchedRepo) : AutopilotRoute
    data object Docs : AutopilotRoute
    data class DocsRepoDetail(val repo: DocsRepo) : AutopilotRoute
    data object Release : AutopilotRoute
    data class ReleaseRepoDetail(val repo: ReleaseRepo) : AutopilotRoute
}

class AutopilotNav(
    private val stack: SnapshotStateList<AutopilotRoute>,
    private val exit: () -> Unit,
) {
    fun push(route: AutopilotRoute) {
        stack.add(route)
    }

    fun pop() {
        if (stack.size > 1) stack.removeAt(stack.lastIndex) else exit()
    }
}

/**
 * Host for the Autopilot settings stack. Rendered full-screen from
 * `SettingsScreen` when the user taps the "Autopilot" row. [onExit] pops the
 * whole feature (back from the hub).
 */
@Composable
fun AutopilotNavHost(
    app: MobileAppState,
    online: Boolean,
    onExit: () -> Unit,
) {
    val stack = remember { mutableStateListOf<AutopilotRoute>(AutopilotRoute.Hub) }
    val nav = remember(stack) { AutopilotNav(stack, onExit) }
    val service = app.autopilot

    BackHandler { nav.pop() }

    when (val route = stack.last()) {
        AutopilotRoute.Hub -> AutopilotHubScreen(service, online, nav)
        AutopilotRoute.Automation -> AutomationScreen(service, online, nav::pop)
        AutopilotRoute.RepoSetup -> RepoSetupScreen(service, online, nav::pop)

        AutopilotRoute.Secrets -> SecretsScreen(app, online, nav)
        is AutopilotRoute.SecretsRepo -> SecretsRepoScreen(app, route.repo, online, nav)
        is AutopilotRoute.SecretsEnv -> SecretsEnvScreen(app, route.repo, route.env, online, nav::pop)

        AutopilotRoute.Ci -> CiUpdatesScreen(service, online, nav)
        is AutopilotRoute.CiRepo -> CiRepoScreen(service, route.repo, online, nav::pop)

        AutopilotRoute.Docs -> DocsScreen(service, online, nav)
        is AutopilotRoute.DocsRepoDetail -> DocsRepoScreen(service, route.repo, online, nav::pop)

        AutopilotRoute.Release -> ReleaseScreen(service, online, nav)
        is AutopilotRoute.ReleaseRepoDetail -> ReleaseRepoScreen(service, route.repo, online, nav::pop)
    }
}
