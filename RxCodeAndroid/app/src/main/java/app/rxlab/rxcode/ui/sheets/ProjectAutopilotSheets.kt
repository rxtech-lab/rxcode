package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MobileReleaseWorkflow
import app.rxlab.rxcode.proto.MobileReleaseWorkflowInput
import app.rxlab.rxcode.proto.Project
import app.rxlab.rxcode.proto.ProjectBranchInfo
import app.rxlab.rxcode.proto.ReleaseDispatchRequest
import app.rxlab.rxcode.proto.SecretsEnvironment
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.autopilot.AutopilotErrorRow
import app.rxlab.rxcode.ui.autopilot.AutopilotSuccessRow
import kotlinx.coroutines.launch

/**
 * On-device "Download Secret" form. Mirrors iOS `ProjectSecretsDownloadSheet`:
 * pick an environment, decrypt it on-device with the phone's passkey-derived
 * KEK, then relay the plaintext for the Mac to write into the project folder.
 * Files skipped because they already exist surface a prompt to enable overwrite.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectSecretsDownloadSheet(
    viewModel: MobileAppState,
    project: Project,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { it != SheetValue.Hidden },
    )
    val repo = project.gitHubRepo

    var environments by remember { mutableStateOf<List<SecretsEnvironment>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var selectedEnvId by remember { mutableStateOf<String?>(null) }
    var overwrite by remember { mutableStateOf(false) }
    var isDownloading by remember { mutableStateOf(false) }
    var actionError by remember { mutableStateOf<String?>(null) }
    var conflicts by remember { mutableStateOf<List<String>>(emptyList()) }

    androidx.compose.runtime.LaunchedEffect(project.id) {
        if (repo == null) {
            loadError = "This project is not linked to a GitHub repo."
            isLoading = false
            return@LaunchedEffect
        }
        isLoading = true
        try {
            val envs = viewModel.autopilot.listSecretEnvironments(repo)
            environments = envs
            if (envs.size == 1) selectedEnvId = envs.first().id
        } catch (t: Throwable) {
            loadError = t.message ?: "Couldn't load environments."
        }
        isLoading = false
    }

    fun download() {
        val envId = selectedEnvId ?: return
        if (repo == null) return
        isDownloading = true
        actionError = null
        conflicts = emptyList()
        scope.launch {
            try {
                val result = viewModel.downloadProjectSecrets(context, project.id, repo, envId, overwrite)
                if (result.conflicts.isNotEmpty()) conflicts = result.conflicts else onDismiss()
            } catch (t: Throwable) {
                actionError = t.message ?: "Couldn't download the secrets."
            } finally {
                isDownloading = false
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            SheetTopBar(
                title = "Download Secret",
                actionLabel = "Download",
                actionEnabled = selectedEnvId != null && !isDownloading,
                actionBusy = isDownloading,
                onCancel = onDismiss,
                onAction = ::download,
            )

            when {
                loadError != null -> Text(loadError!!, color = MaterialTheme.colorScheme.error)
                isLoading && environments.isEmpty() -> CenteredSpinner()
                environments.isEmpty() -> Text(
                    "This repository has no secret environments to download.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                else -> {
                    Text(
                        "Environment",
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    environments.forEach { env ->
                        SelectableRow(
                            label = env.name,
                            selected = selectedEnvId == env.id,
                            onClick = { selectedEnvId = env.id },
                        )
                    }
                    Text(
                        "Files are decrypted on this device with your passkey, then written into the project folder on your Mac.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text("Overwrite existing files", style = MaterialTheme.typography.bodyMedium)
                        Switch(checked = overwrite, onCheckedChange = { overwrite = it })
                    }
                    if (conflicts.isNotEmpty()) {
                        AutopilotErrorRow(
                            "These files already exist and were skipped: ${conflicts.joinToString(", ")}. " +
                                "Turn on overwrite to replace them.",
                        )
                    }
                    if (actionError != null) {
                        Text(actionError!!, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            Spacer(Modifier.height(4.dp))
        }
    }
}

/**
 * On-device "Create Release" form. Mirrors iOS `ProjectReleaseCreateSheet`:
 * resolve the project's release workflows, pick a dispatchable one, fill its
 * `workflow_dispatch` inputs, and trigger it (the desktop only relays). The next
 * version is computed by semantic-release from the commit history.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectReleaseCreateSheet(
    viewModel: MobileAppState,
    project: Project,
    branchInfo: ProjectBranchInfo?,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { it != SheetValue.Hidden },
    )
    val repo = project.gitHubRepo.orEmpty()
    val branchOptions = remember(branchInfo) {
        val current = branchInfo?.currentBranch
        val all = branchInfo?.availableBranches.orEmpty()
        when {
            all.isNotEmpty() && current != null -> listOf(current) + all.filter { it != current }
            all.isNotEmpty() -> all
            current != null -> listOf(current)
            else -> emptyList()
        }
    }

    var workflows by remember { mutableStateOf<List<MobileReleaseWorkflow>>(emptyList()) }
    var selectedWorkflowId by remember { mutableStateOf<String?>(null) }
    var branch by remember { mutableStateOf(branchInfo?.currentBranch ?: branchOptions.firstOrNull() ?: "main") }
    var inputValues by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var isLoading by remember { mutableStateOf(true) }
    var isDispatching by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var dispatchError by remember { mutableStateOf<String?>(null) }
    var dispatchedUrl by remember { mutableStateOf<String?>(null) }

    val dispatchable = remember(workflows) { workflows.filter { it.hasWorkflowDispatch } }
    val selectedWorkflow = remember(workflows, selectedWorkflowId) { workflows.firstOrNull { it.id == selectedWorkflowId } }

    fun seedDefaults(workflow: MobileReleaseWorkflow?) {
        val inputs = workflow?.inputs ?: return
        val next = inputValues.toMutableMap()
        inputs.forEach { input ->
            if (next[input.name] == null) {
                next[input.name] = if (input.type == "boolean") {
                    if (input.defaultBool == true) "true" else "false"
                } else {
                    input.defaultString ?: input.options?.firstOrNull() ?: ""
                }
            }
        }
        inputValues = next
    }

    androidx.compose.runtime.LaunchedEffect(project.id) {
        if (repo.isEmpty()) {
            loadError = "This project is not linked to a GitHub repo."
            isLoading = false
            return@LaunchedEffect
        }
        isLoading = true
        try {
            val list = viewModel.autopilot.listReleaseWorkflows(repo)
            workflows = list
            val preferred = list.firstOrNull { it.isSelected && it.hasWorkflowDispatch }
                ?: list.firstOrNull { it.hasWorkflowDispatch }
            selectedWorkflowId = preferred?.id
            seedDefaults(preferred)
        } catch (t: Throwable) {
            loadError = t.message ?: "Couldn't load workflows."
        }
        isLoading = false
    }

    fun dispatch() {
        val workflow = selectedWorkflow ?: return
        val resolvedBranch = branch.trim()
        if (resolvedBranch.isEmpty()) return
        isDispatching = true
        dispatchError = null
        scope.launch {
            try {
                val result = viewModel.autopilot.dispatchRelease(
                    repo,
                    ReleaseDispatchRequest(workflowId = workflow.id, branch = resolvedBranch, inputs = inputValues),
                )
                when {
                    result.workflowRunUrl != null -> dispatchedUrl = result.workflowRunUrl
                    result.success == false -> dispatchError = result.error ?: "Failed to trigger the release workflow."
                    else -> dispatchedUrl = "https://github.com/$repo/actions"
                }
            } catch (t: Throwable) {
                dispatchError = t.message ?: "Failed to trigger the release workflow."
            } finally {
                isDispatching = false
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 16.dp)
                .heightIn(max = 560.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            SheetTopBar(
                title = "Create Release",
                actionLabel = if (dispatchedUrl == null) "Create" else "Done",
                actionEnabled = dispatchedUrl != null ||
                    (!isDispatching && selectedWorkflow != null && branch.trim().isNotEmpty()),
                actionBusy = isDispatching,
                onCancel = onDismiss,
                onAction = { if (dispatchedUrl != null) onDismiss() else dispatch() },
            )

            when {
                isLoading -> CenteredSpinner()
                loadError != null -> Text(loadError!!, color = MaterialTheme.colorScheme.error)
                dispatchable.isEmpty() -> Text(
                    "No dispatchable release workflow found for $repo. Add a workflow_dispatch release " +
                        "workflow and rescan, then try again.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                else -> {
                    LabeledValue("Repository", repo)
                    if (dispatchable.size > 1) {
                        PickerRow(
                            label = "Workflow",
                            value = selectedWorkflow?.displayName ?: "Select",
                            options = dispatchable.map { it.displayName },
                            onSelectIndex = { idx ->
                                val wf = dispatchable[idx]
                                selectedWorkflowId = wf.id
                                seedDefaults(wf)
                            },
                        )
                    } else {
                        LabeledValue("Workflow", dispatchable.first().displayName)
                    }
                    if (branchOptions.isEmpty()) {
                        OutlinedTextField(
                            value = branch,
                            onValueChange = { branch = it },
                            label = { Text("Branch") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        PickerRow(
                            label = "Branch",
                            value = branch,
                            options = branchOptions,
                            onSelectIndex = { branch = branchOptions[it] },
                        )
                    }
                    Text(
                        "The next version is computed by semantic-release from the commit history.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )

                    selectedWorkflow?.inputs?.takeIf { it.isNotEmpty() }?.let { inputs ->
                        Text(
                            "Workflow inputs",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        inputs.forEach { input ->
                            ReleaseInputField(
                                input = input,
                                value = inputValues[input.name],
                                onValueChange = { inputValues = inputValues + (input.name to it) },
                            )
                        }
                    }

                    if (dispatchError != null) {
                        AutopilotErrorRow(dispatchError!!)
                    }
                    if (dispatchedUrl != null) {
                        AutopilotSuccessRow("Release workflow triggered")
                        TextButton(onClick = { uriHandler.openUri(dispatchedUrl!!) }) {
                            Icon(Icons.AutoMirrored.Outlined.OpenInNew, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("View workflow run on GitHub")
                        }
                    }
                }
            }
            Spacer(Modifier.height(4.dp))
        }
    }
}

// MARK: - Shared sheet pieces

@Composable
private fun SheetTopBar(
    title: String,
    actionLabel: String,
    actionEnabled: Boolean,
    actionBusy: Boolean,
    onCancel: () -> Unit,
    onAction: () -> Unit,
) {
    Box(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.CenterStart)) { Text("Cancel") }
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.align(Alignment.Center),
        )
        Box(Modifier.align(Alignment.CenterEnd)) {
            if (actionBusy) {
                CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
            } else {
                TextButton(onClick = onAction, enabled = actionEnabled) {
                    Text(actionLabel, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun CenteredSpinner() {
    Box(Modifier.fillMaxWidth().padding(vertical = 24.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}

@Composable
private fun SelectableRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        color = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            if (selected) Icon(Icons.Outlined.Check, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        }
    }
}

@Composable
private fun LabeledValue(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun PickerRow(
    label: String,
    value: String,
    options: List<String>,
    onSelectIndex: (Int) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth()) {
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().clickable { open = true },
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(value, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium)
                    Icon(Icons.Outlined.ExpandMore, contentDescription = null, modifier = Modifier.size(18.dp))
                }
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEachIndexed { idx, option ->
                DropdownMenuItem(
                    text = { Text(option) },
                    onClick = { open = false; onSelectIndex(idx) },
                )
            }
        }
    }
}

@Composable
private fun ReleaseInputField(
    input: MobileReleaseWorkflowInput,
    value: String?,
    onValueChange: (String) -> Unit,
) {
    val label = input.name + (if (input.required) " *" else "")
    when {
        input.type == "boolean" -> {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(label, style = MaterialTheme.typography.bodyMedium)
                Switch(
                    checked = (value ?: if (input.defaultBool == true) "true" else "false") == "true",
                    onCheckedChange = { onValueChange(if (it) "true" else "false") },
                )
            }
        }
        input.type == "choice" && input.options != null -> {
            val options = input.options!!
            PickerRow(
                label = label,
                value = value ?: input.defaultString ?: options.firstOrNull() ?: "",
                options = options,
                onSelectIndex = { onValueChange(options[it]) },
            )
        }
        else -> {
            OutlinedTextField(
                value = value ?: input.defaultString ?: "",
                onValueChange = onValueChange,
                label = { Text(label) },
                supportingText = input.description?.takeIf { it.isNotEmpty() }?.let { { Text(it) } },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
