package app.rxlab.rxcode.ui.autopilot

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MenuAction
import app.rxlab.rxcode.proto.MenuActionCommand
import app.rxlab.rxcode.proto.MenuCommandKind
import app.rxlab.rxcode.proto.MenuItem
import app.rxlab.rxcode.proto.Project
import app.rxlab.rxcode.proto.ProjectBranchInfo
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.sheets.ProjectReleaseCreateSheet
import app.rxlab.rxcode.ui.sheets.ProjectSecretsDownloadSheet
import kotlinx.coroutines.launch

/**
 * The project / briefing actions menu — now a thin renderer of the **desktop's**
 * serialized context menu. The Mac builds the same `[MenuItem]` its own menus
 * render (from its hooks: Code Review, Commit, Create PR, Fix CI, plus the
 * autopilot secrets/docs/release/CI setup items) and ships it over the relay;
 * Android decodes and renders the identical items, exactly like iOS — so the
 * menu's contents, gating, and per-item behavior have one source of truth.
 *
 * `.command` items run on the Mac via [MobileAppState.executeMenuCommand] (an
 * `isAsync` command — e.g. Create PR — blocks behind a loading dialog and waits);
 * `.deepLink` items open the matching on-device sheet / setup chat. "Open on
 * GitHub" and the optional destructive "Delete Project" are Android-local extras
 * the desktop menu doesn't carry.
 *
 * @param branch current branch — scopes the fetched menu (briefing cards target
 *   their own branch); `"unknown"` is treated as no branch.
 * @param prNumber the open PR number for [branch], if any — only used to refetch
 *   the menu when PR state changes (the desktop decides whether "Create PR" shows).
 * @param onOpenSession navigate to a chat after an action spawns / targets one.
 * @param onProjectDeleted called after confirming "Delete Project".
 */
@Composable
fun ProjectActionsMenu(
    project: Project,
    branch: String?,
    branchInfo: ProjectBranchInfo?,
    viewModel: MobileAppState,
    prNumber: Int? = null,
    includeDeleteProject: Boolean = false,
    onOpenSession: (String) -> Unit = {},
    onProjectDeleted: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val hasRepo = !project.gitHubRepo.isNullOrEmpty()
    val scopedBranch = branch?.takeIf { it.isNotEmpty() && !it.equals("unknown", ignoreCase = true) }

    var menuOpen by remember { mutableStateOf(false) }
    var menuItems by remember(project.id) { mutableStateOf<List<MenuItem>?>(null) }
    var showDownload by remember { mutableStateOf(false) }
    var showReleaseCreate by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }
    // Set to a command's kind while an async command runs, driving the loading
    // dialog; a non-async command never sets it. `dispatching` guards re-entrancy.
    var dispatching by remember { mutableStateOf(false) }
    var asyncCommand by remember { mutableStateOf<MenuCommandKind?>(null) }
    var info by remember { mutableStateOf<String?>(null) }

    // Prefetch the desktop menu, re-keyed on the git-dirty + PR state it's gated
    // by so it refreshes after commits / PR creation land in the snapshot.
    LaunchedEffect(project.id, scopedBranch, branchInfo?.hasUncommittedChanges, prNumber) {
        menuItems = runCatching { viewModel.fetchProjectMenu(project.id, scopedBranch) }.getOrNull()
    }

    fun startSetupChat(prompt: String) {
        menuOpen = false
        val sessionId = viewModel.startNewSession(projectId = project.id, initialText = prompt)
        onOpenSession(sessionId)
    }

    fun runCommand(command: MenuActionCommand) {
        if (dispatching) return
        menuOpen = false
        dispatching = true
        if (command.isAsync) asyncCommand = command.kind
        scope.launch {
            try {
                val result = viewModel.executeMenuCommand(command)
                viewModel.requestSnapshot("menu_command")
                result.threadId?.let { onOpenSession(it) }
                result.openURL?.let { uriHandler.openUri(it) }
            } catch (t: Throwable) {
                info = t.message ?: "Couldn't complete the action."
            } finally {
                dispatching = false
                asyncCommand = null
            }
        }
    }

    fun handleDeepLink(url: String) {
        menuOpen = false
        when (val target = mobileMenuDeepLinkTarget(url)) {
            is MobileMenuDeepLinkTarget.SecretsDownload -> showDownload = true
            is MobileMenuDeepLinkTarget.ReleaseCreate -> showReleaseCreate = true
            is MobileMenuDeepLinkTarget.SetupChat -> startSetupChat(target.prompt)
            is MobileMenuDeepLinkTarget.None -> Unit
        }
    }

    fun handleAction(action: MenuAction?) {
        when (action) {
            is MenuAction.Command -> runCommand(action.command)
            is MenuAction.DeepLink -> handleDeepLink(action.url)
            null -> Unit
        }
    }

    IconButton(onClick = { menuOpen = true }) {
        Icon(Icons.Outlined.MoreVert, contentDescription = "Project actions")
    }

    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
        val items = menuItems
        if (items == null) {
            DropdownMenuItem(
                text = { Text("Loading…") },
                leadingIcon = { Icon(Icons.Outlined.HourglassEmpty, contentDescription = null) },
                enabled = false,
                onClick = {},
            )
        } else {
            SerializedMenuItems(items, onAction = ::handleAction)
        }

        // Android-local extras the desktop menu doesn't carry.
        if (hasRepo) {
            if (!items.isNullOrEmpty()) HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Open on GitHub") },
                leadingIcon = { Icon(Icons.AutoMirrored.Outlined.OpenInNew, contentDescription = null) },
                onClick = {
                    menuOpen = false
                    uriHandler.openUri("https://github.com/${project.gitHubRepo}")
                },
            )
        }

        if (includeDeleteProject) {
            if (hasRepo || !items.isNullOrEmpty()) HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Delete Project", color = MaterialTheme.colorScheme.error) },
                leadingIcon = {
                    Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                },
                onClick = { menuOpen = false; showDeleteConfirm = true },
            )
        }
    }

    if (showDownload) {
        ProjectSecretsDownloadSheet(viewModel = viewModel, project = project, onDismiss = { showDownload = false })
    }

    if (showReleaseCreate) {
        ProjectReleaseCreateSheet(
            viewModel = viewModel,
            project = project,
            branchInfo = branchInfo,
            onDismiss = { showReleaseCreate = false },
        )
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            icon = { Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
            title = { Text("Delete project?") },
            text = {
                Text(
                    "This permanently removes \"${project.name}\" and all its threads, search index, and memory " +
                        "from both your Mac and this device.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirm = false
                    viewModel.deleteProject(project.id)
                    onProjectDeleted()
                }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") } },
        )
    }

    asyncCommand?.let { kind ->
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

    info?.let { message ->
        AlertDialog(
            onDismissRequest = { info = null },
            title = { Text("Couldn't Complete") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { info = null }) { Text("OK") } },
        )
    }
}
