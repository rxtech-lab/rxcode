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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.AddReleaseRepoBody
import app.rxlab.rxcode.proto.MobileReleaseWorkflow
import app.rxlab.rxcode.proto.ReleaseDispatchRequest
import app.rxlab.rxcode.proto.ReleaseRepo
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.AutopilotService
import kotlinx.coroutines.launch

@Composable
fun ReleaseScreen(
    service: AutopilotService,
    online: Boolean,
    nav: AutopilotNav,
) {
    val scope = rememberCoroutineScope()
    var repos by remember { mutableStateOf<List<ReleaseRepo>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var showPicker by remember { mutableStateOf(false) }
    var deleteTarget by remember { mutableStateOf<ReleaseRepo?>(null) }

    LaunchedEffect(online, reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            repos = service.listReleaseRepos().items
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    AutopilotScaffold(
        title = "Releases",
        onBack = { nav.pop() },
        actions = {
            IconButton(enabled = online, onClick = { showPicker = true }) {
                Icon(Icons.Outlined.Add, contentDescription = "Add release repository")
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
                    item { AutopilotEmptyState("No release repositories. Tap + to add one.") }
                }
                items(repos, key = { it.id }) { repo ->
                    RepoListCard(
                        title = repo.fullName,
                        subtitle = repo.latestReleaseTag?.let { "Latest: $it" },
                        enabled = online,
                        onClick = { nav.push(AutopilotRoute.ReleaseRepoDetail(repo)) },
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
            title = "Add Release Repository",
            existingFullNames = repos.map { it.fullName }.toSet(),
            onSelect = { picked ->
                service.addReleaseRepo(AddReleaseRepoBody(picked.installationId, picked.id, picked.fullName))
                reloadKey++
            },
            onDismiss = { showPicker = false },
        )
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Remove repository?") },
            text = { Text("\"${target.fullName}\" will be removed from release management.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try { service.deleteReleaseRepo(target.id); reloadKey++ }
                        catch (e: AutopilotException) { errorMessage = e.message }
                    }
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
fun ReleaseRepoScreen(
    service: AutopilotService,
    repo: ReleaseRepo,
    online: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var workflows by remember { mutableStateOf<List<MobileReleaseWorkflow>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var tokenValue by remember { mutableStateOf("") }
    var isInstallingToken by remember { mutableStateOf(false) }
    var reloadKey by remember { mutableStateOf(0) }
    var dispatchWorkflow by remember { mutableStateOf<MobileReleaseWorkflow?>(null) }

    LaunchedEffect(reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            workflows = service.listReleaseWorkflows(repo.id)
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    dispatchWorkflow?.let { workflow ->
        ReleaseDispatchScreen(
            service = service,
            repoId = repo.id,
            workflow = workflow,
            online = online,
            onClose = { dispatchWorkflow = null },
            onDispatched = { message -> dispatchWorkflow = null; statusMessage = message; reloadKey++ },
        )
        return
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

                item { AutopilotSectionLabel("Workflows") }
                if (workflows.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No workflows scanned yet.") }
                }
                items(workflows, key = { it.id }) { workflow ->
                    WorkflowRow(workflow, online) { dispatchWorkflow = workflow }
                }

                item { AutopilotSectionLabel("RELEASE_TOKEN") }
                item {
                    Text(
                        "Installed as the repo's GitHub Actions secret so the release workflow can publish.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                item {
                    OutlinedTextField(
                        value = tokenValue,
                        onValueChange = { tokenValue = it },
                        label = { Text("ghp_… or github_pat_…") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                item {
                    OutlinedButton(
                        enabled = online && !isInstallingToken && tokenValue.isNotBlank(),
                        onClick = {
                            isInstallingToken = true
                            errorMessage = null
                            statusMessage = null
                            scope.launch {
                                try {
                                    val r = service.installReleaseToken(repo.id, tokenValue)
                                    statusMessage = "Installed ${r.secretName}."
                                    tokenValue = ""
                                } catch (e: AutopilotException) {
                                    errorMessage = e.message
                                } finally {
                                    isInstallingToken = false
                                }
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (isInstallingToken) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            Text("  Installing…")
                        } else {
                            Icon(Icons.Outlined.Key, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text("  Install RELEASE_TOKEN")
                        }
                    }
                }
            }
            AutopilotLoadingOverlay(isLoading && workflows.isEmpty())
        }
    }
}

@Composable
private fun WorkflowRow(
    workflow: MobileReleaseWorkflow,
    online: Boolean,
    onRelease: () -> Unit,
) {
    ElevatedCard(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                Text(workflow.displayName, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(workflow.workflowPath, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (workflow.isSelected) {
                Icon(Icons.Outlined.CheckCircle, contentDescription = "Selected", tint = AutopilotSuccess, modifier = Modifier.size(20.dp))
            }
            if (workflow.hasWorkflowDispatch) {
                TextButton(enabled = online, onClick = onRelease) { Text("Release") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReleaseDispatchScreen(
    service: AutopilotService,
    repoId: String,
    workflow: MobileReleaseWorkflow,
    online: Boolean,
    onClose: () -> Unit,
    onDispatched: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var branch by remember { mutableStateOf("main") }
    val inputValues = remember { mutableStateMapOf<String, String>() }
    var isDispatching by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Seed defaults once.
    LaunchedEffect(workflow.id) {
        workflow.inputs?.forEach { input ->
            val default = input.defaultString ?: input.defaultBool?.toString()
            if (default != null) inputValues[input.name] = default
        }
    }

    AutopilotScaffold(
        title = "Create Release",
        onBack = onClose,
        actions = {
            TextButton(
                enabled = online && !isDispatching && branch.isNotBlank(),
                onClick = {
                    isDispatching = true
                    errorMessage = null
                    scope.launch {
                        try {
                            val result = service.dispatchRelease(
                                repoId,
                                ReleaseDispatchRequest(
                                    workflowId = workflow.id,
                                    branch = branch.trim(),
                                    inputs = inputValues.toMap(),
                                ),
                            )
                            if (result.success == false && result.error != null) {
                                errorMessage = result.error
                            } else {
                                onDispatched("Release dispatched.")
                            }
                        } catch (e: AutopilotException) {
                            errorMessage = e.message
                        } finally {
                            isDispatching = false
                        }
                    }
                },
            ) { Text("Dispatch") }
        },
    ) { m ->
        Column(
            m.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AutopilotSectionLabel("Branch")
            OutlinedTextField(
                value = branch,
                onValueChange = { branch = it },
                placeholder = { Text("main") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            val inputs = workflow.inputs.orEmpty()
            if (inputs.isNotEmpty()) {
                AutopilotSectionLabel("Inputs")
                inputs.forEach { input ->
                    val value = inputValues[input.name] ?: ""
                    when {
                        input.type == "boolean" -> {
                            Row(
                                Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(input.name, style = MaterialTheme.typography.bodyLarge)
                                Switch(
                                    checked = value == "true",
                                    onCheckedChange = { inputValues[input.name] = it.toString() },
                                )
                            }
                        }
                        input.type == "choice" && !input.options.isNullOrEmpty() -> {
                            var expanded by remember(input.name) { mutableStateOf(false) }
                            ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
                                OutlinedTextField(
                                    value = value,
                                    onValueChange = {},
                                    readOnly = true,
                                    label = { Text(input.name) },
                                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                                    modifier = Modifier.fillMaxWidth().menuAnchor(),
                                )
                                ExposedDropdownMenu(
                                    expanded = expanded,
                                    onDismissRequest = { expanded = false },
                                ) {
                                    input.options.forEach { option ->
                                        DropdownMenuItem(
                                            text = { Text(option) },
                                            onClick = { inputValues[input.name] = option; expanded = false },
                                        )
                                    }
                                }
                            }
                        }
                        else -> {
                            OutlinedTextField(
                                value = value,
                                onValueChange = { inputValues[input.name] = it },
                                label = { Text(input.name) },
                                placeholder = { input.description?.let { Text(it) } },
                                singleLine = true,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            }

            errorMessage?.let { AutopilotErrorRow(it) }
        }
    }
}
