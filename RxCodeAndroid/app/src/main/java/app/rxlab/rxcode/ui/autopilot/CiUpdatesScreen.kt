package app.rxlab.rxcode.ui.autopilot

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Loop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.AddWatchedRepoBody
import app.rxlab.rxcode.proto.CIPullRequest
import app.rxlab.rxcode.proto.CIScanFrequency
import app.rxlab.rxcode.proto.CIUpdateRunHistory
import app.rxlab.rxcode.proto.WatchedRepo
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.AutopilotService
import kotlinx.coroutines.launch

@Composable
fun CiUpdatesScreen(
    service: AutopilotService,
    online: Boolean,
    nav: AutopilotNav,
) {
    val scope = rememberCoroutineScope()
    var repos by remember { mutableStateOf<List<WatchedRepo>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var showPicker by remember { mutableStateOf(false) }
    var deleteTarget by remember { mutableStateOf<WatchedRepo?>(null) }

    LaunchedEffect(online, reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            repos = service.listWatchedRepos().repositories
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    AutopilotScaffold(
        title = "CI Auto-Update",
        onBack = { nav.pop() },
        actions = {
            IconButton(enabled = online, onClick = { showPicker = true }) {
                Icon(Icons.Outlined.Add, contentDescription = "Watch repository")
            }
        },
    ) { m ->
        Box(m.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                errorMessage?.let { item { AutopilotErrorRow(it) } }
                if (repos.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No watched repositories. Tap + to add one.") }
                }
                items(repos, key = { it.id }) { repo ->
                    RepoListCard(
                        title = repo.fullName,
                        subtitle = repo.scanFrequency.displayName,
                        enabled = online,
                        onClick = { nav.push(AutopilotRoute.CiRepo(repo)) },
                        onDelete = { deleteTarget = repo },
                    )
                }
            }
            AutopilotLoadingOverlay(isLoading && repos.isEmpty())
        }
    }

    if (showPicker) {
        AutopilotRepoPicker(
            service = service,
            title = "Watch Repository",
            existingFullNames = repos.map { it.fullName }.toSet(),
            onSelect = { picked ->
                service.addWatchedRepo(
                    AddWatchedRepoBody(
                        installationId = picked.installationId,
                        repositoryId = picked.id,
                        repositoryFullName = picked.fullName,
                        scanFrequency = CIScanFrequency.WEEKLY,
                    )
                )
                reloadKey++
            },
            onDismiss = { showPicker = false },
        )
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Stop watching?") },
            text = { Text("\"${target.fullName}\" will no longer be scanned for outdated actions.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try { service.deleteWatchedRepo(target.id); reloadKey++ }
                        catch (e: AutopilotException) { errorMessage = e.message }
                    }
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
fun CiRepoScreen(
    service: AutopilotService,
    repo: WatchedRepo,
    online: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var frequency by remember { mutableStateOf(repo.scanFrequency) }
    var history by remember { mutableStateOf<List<CIUpdateRunHistory>>(emptyList()) }
    var pullRequests by remember { mutableStateOf<List<CIPullRequest>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var isTriggering by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var closeTarget by remember { mutableStateOf<CIPullRequest?>(null) }

    LaunchedEffect(reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            history = service.watchedRepoHistory(repo.id, limit = 50)
            pullRequests = service.watchedRepoPullRequests(repo.id)
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    AutopilotScaffold(title = repo.fullName, onBack = onBack) { m ->
        Box(m.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                errorMessage?.let { item { AutopilotErrorRow(it) } }
                statusMessage?.let { item { AutopilotSuccessRow(it) } }

                item { AutopilotSectionLabel("Scan") }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CIScanFrequency.entries.forEach { freq ->
                            FilterChip(
                                selected = frequency == freq,
                                enabled = online,
                                onClick = {
                                    frequency = freq
                                    scope.launch {
                                        try { service.updateWatchedRepoFrequency(repo.id, freq) }
                                        catch (e: AutopilotException) { errorMessage = e.message }
                                    }
                                },
                                label = { Text(freq.displayName) },
                            )
                        }
                    }
                }
                item {
                    OutlinedButton(
                        enabled = online && !isTriggering,
                        onClick = {
                            isTriggering = true
                            errorMessage = null
                            statusMessage = null
                            scope.launch {
                                try {
                                    val r = service.triggerWatchedRepoScan(repo.id)
                                    statusMessage = if (r.success) "Scan started." else (r.error ?: "Scan failed.")
                                    reloadKey++
                                } catch (e: AutopilotException) {
                                    errorMessage = e.message
                                } finally {
                                    isTriggering = false
                                }
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (isTriggering) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Text("  Scanning…")
                        } else {
                            Icon(Icons.Outlined.Loop, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text("  Trigger scan now")
                        }
                    }
                }

                item { AutopilotSectionLabel("Scan History") }
                if (history.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No scans yet.") }
                }
                items(history, key = { it.id }) { run -> HistoryRow(run) }

                item { AutopilotSectionLabel("Pull Requests") }
                if (pullRequests.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No open auto-update pull requests.") }
                }
                items(pullRequests, key = { it.stableId }) { pr ->
                    PullRequestRow(pr, online) { closeTarget = pr }
                }
            }
            AutopilotLoadingOverlay(isLoading && history.isEmpty() && pullRequests.isEmpty())
        }
    }

    closeTarget?.let { pr ->
        AlertDialog(
            onDismissRequest = { closeTarget = null },
            title = { Text("Close pull request?") },
            text = { Text(pr.title ?: "PR #${pr.number ?: "?"}") },
            confirmButton = {
                TextButton(onClick = {
                    val number = pr.number
                    closeTarget = null
                    if (number != null) {
                        scope.launch {
                            try { service.closeWatchedRepoPR(repo.id, number); reloadKey++ }
                            catch (e: AutopilotException) { errorMessage = e.message }
                        }
                    }
                }) { Text("Close PR", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { closeTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun HistoryRow(run: CIUpdateRunHistory) {
    ElevatedCard(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    if (run.isSuccess) Icons.Outlined.CheckCircle else Icons.Outlined.Cancel,
                    contentDescription = null,
                    tint = if (run.isSuccess) AutopilotSuccess else MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    if (run.isSuccess) "Success" else "Error",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            run.outdatedActionsCount?.let {
                Text(
                    "$it outdated action(s)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            run.errorMessage?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            run.prUrl?.let {
                Text("PR: $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun PullRequestRow(pr: CIPullRequest, online: Boolean, onClose: () -> Unit) {
    ElevatedCard(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                Text(pr.title ?: "PR #${pr.number ?: "?"}", style = MaterialTheme.typography.bodyMedium)
                pr.number?.let {
                    Text("#$it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            IconButton(enabled = online, onClick = onClose) {
                Icon(Icons.Outlined.Cancel, contentDescription = "Close PR", tint = MaterialTheme.colorScheme.error)
            }
        }
    }
}

/** Shared list-card used by CI / Docs / Release repo lists. */
@Composable
fun RepoListCard(
    title: String,
    subtitle: String?,
    enabled: Boolean,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = { if (enabled) onClick() },
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                subtitle?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Outlined.Delete, contentDescription = "Remove", tint = MaterialTheme.colorScheme.error)
            }
        }
    }
}
