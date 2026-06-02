package app.rxlab.rxcode.ui.autopilot

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MergeType
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Sell
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.AutopilotProjectStatus
import app.rxlab.rxcode.proto.Project
import app.rxlab.rxcode.proto.ProjectBranchInfo
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.sheets.ProjectReleaseCreateSheet
import app.rxlab.rxcode.ui.sheets.ProjectSecretsDownloadSheet
import kotlinx.coroutines.launch

private const val SECRETS_SETUP_PROMPT =
    "Set up encrypted secrets for this repository so I can sync environment files securely."
private const val DOCS_SETUP_PROMPT =
    "Set up documentation publishing for this repository so its docs are indexed into RxCode docs search."
private const val RELEASE_SETUP_PROMPT =
    "Set up a release workflow for this repository (semantic-release + a GitHub Actions release workflow)."

/**
 * One-to-one mobile mirror of the desktop project/briefing autopilot context
 * menu (`ProjectAutopilotMenuItems` on iOS), plus the per-screen extras: a
 * "Create Pull Request" / "Open on GitHub" pair (briefing detail) and an
 * optional destructive "Delete Project" (session list).
 *
 * Drop into a `TopAppBar`'s `actions = { }`. Autopilot items only appear for
 * repo-backed projects, gated on the per-project [AutopilotProjectStatus] this
 * loads on first composition. Every item is desktop-mediated except "Download
 * Secret", which decrypts on-device and relays plaintext for the Mac to write.
 *
 * @param branch current branch — enables "Create Pull Request" (hidden when null
 *   or `"unknown"`) and seeds the release form's branch picker.
 * @param onOpenSession navigate to a chat after a setup action creates one.
 * @param onProjectDeleted called after confirming "Delete Project" so the host
 *   can pop back (only reachable when [includeDeleteProject] is true).
 */
@Composable
fun ProjectActionsMenu(
    project: Project,
    branch: String?,
    branchInfo: ProjectBranchInfo?,
    viewModel: MobileAppState,
    includeDeleteProject: Boolean = false,
    onOpenSession: (String) -> Unit = {},
    onProjectDeleted: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val hasRepo = !project.gitHubRepo.isNullOrEmpty()
    val canCreatePR = branch != null && !branch.equals("unknown", ignoreCase = true)

    var menuOpen by remember { mutableStateOf(false) }
    var status by remember(project.id) { mutableStateOf<AutopilotProjectStatus?>(null) }
    var showDownload by remember { mutableStateOf(false) }
    var showReleaseCreate by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }
    var isCreatingPR by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf<String?>(null) }

    // Only repo-backed projects have autopilot state to load.
    androidx.compose.runtime.LaunchedEffect(project.id) {
        if (hasRepo) status = runCatching { viewModel.projectAutopilotStatus(project.id) }.getOrNull()
    }

    fun startSetupChat(prompt: String) {
        menuOpen = false
        val sessionId = viewModel.startNewSession(projectId = project.id, initialText = prompt)
        onOpenSession(sessionId)
    }

    fun createPullRequest() {
        if (isCreatingPR || branch == null) return
        isCreatingPR = true
        menuOpen = false
        scope.launch {
            try {
                val url = viewModel.requestProjectCreatePullRequest(project.id, branch)
                viewModel.requestSnapshot("pr_created")
                uriHandler.openUri(url)
            } catch (t: Throwable) {
                info = t.message ?: "Couldn't create the pull request."
            } finally {
                isCreatingPR = false
            }
        }
    }

    IconButton(onClick = { menuOpen = true }) {
        Icon(Icons.Outlined.MoreVert, contentDescription = "Project actions")
    }

    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
        if (hasRepo) {
            val loaded = status
            if (loaded == null) {
                DropdownMenuItem(
                    text = { Text("Loading Autopilot…") },
                    leadingIcon = { Icon(Icons.Outlined.HourglassEmpty, contentDescription = null) },
                    enabled = false,
                    onClick = {},
                )
            } else {
                // Secrets: download when present, otherwise offer setup.
                if (loaded.hasSecrets) {
                    DropdownMenuItem(
                        text = { Text("Download Secret") },
                        leadingIcon = { Icon(Icons.Outlined.Key, contentDescription = null) },
                        onClick = { menuOpen = false; showDownload = true },
                    )
                } else {
                    DropdownMenuItem(
                        text = { Text("Set Up Secrets") },
                        leadingIcon = { Icon(Icons.Outlined.Key, contentDescription = null) },
                        onClick = { startSetupChat(SECRETS_SETUP_PROMPT) },
                    )
                }
                // Docs: only offer setup when not yet indexed.
                if (!loaded.hasDocs) {
                    DropdownMenuItem(
                        text = { Text("Set Up Docs") },
                        leadingIcon = { Icon(Icons.Outlined.Book, contentDescription = null) },
                        onClick = { startSetupChat(DOCS_SETUP_PROMPT) },
                    )
                }
                // Release: create when configured, otherwise offer setup.
                if (loaded.hasRelease) {
                    DropdownMenuItem(
                        text = { Text("Create Release") },
                        leadingIcon = { Icon(Icons.Outlined.Sell, contentDescription = null) },
                        onClick = { menuOpen = false; showReleaseCreate = true },
                    )
                } else {
                    DropdownMenuItem(
                        text = { Text("Set Up Release Workflow") },
                        leadingIcon = { Icon(Icons.Outlined.Sell, contentDescription = null) },
                        onClick = { startSetupChat(RELEASE_SETUP_PROMPT) },
                    )
                }
                if (canCreatePR) {
                    DropdownMenuItem(
                        text = { Text("Create Pull Request") },
                        leadingIcon = { Icon(Icons.AutoMirrored.Outlined.MergeType, contentDescription = null) },
                        enabled = !isCreatingPR,
                        onClick = { createPullRequest() },
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("Open on GitHub") },
                    leadingIcon = { Icon(Icons.AutoMirrored.Outlined.OpenInNew, contentDescription = null) },
                    onClick = {
                        menuOpen = false
                        uriHandler.openUri("https://github.com/${project.gitHubRepo}")
                    },
                )
            }
        }

        if (includeDeleteProject) {
            if (hasRepo) HorizontalDivider()
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

    if (isCreatingPR) {
        AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            title = { Text("Creating Pull Request…") },
            text = {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                    Text("The Mac is pushing the branch and opening the PR.")
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
