package app.rxlab.rxcode.ui.autopilot

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
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
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.RepoSetupTemplate
import app.rxlab.rxcode.proto.RepoSetupTemplateInput
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.AutopilotService
import app.rxlab.rxcode.ui.jsonschemaform.JsonSchemaForm
import app.rxlab.rxcode.ui.jsonschemaform.rememberJsonSchemaFormState
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** Distinguishes the editor's create vs. edit modes. */
private sealed interface RepoSetupEditTarget {
    data object New : RepoSetupEditTarget
    data class Existing(val template: RepoSetupTemplate) : RepoSetupEditTarget
}

@Composable
fun RepoSetupScreen(
    service: AutopilotService,
    online: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var templates by remember { mutableStateOf<List<RepoSetupTemplate>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var reloadKey by remember { mutableStateOf(0) }
    var editing by remember { mutableStateOf<RepoSetupEditTarget?>(null) }
    var deleteTarget by remember { mutableStateOf<RepoSetupTemplate?>(null) }

    LaunchedEffect(online, reloadKey) {
        if (!online) { isLoading = false; return@LaunchedEffect }
        isLoading = true
        errorMessage = null
        try {
            templates = service.repoSetupTemplates()
        } catch (e: AutopilotException) {
            errorMessage = e.message
        } finally {
            isLoading = false
        }
    }

    editing?.let { target ->
        RepoSetupEditor(
            target = target,
            service = service,
            online = online,
            onClose = { editing = null },
            onSaved = { editing = null; reloadKey++ },
        )
        return
    }

    AutopilotScaffold(
        title = "Repo Setup",
        onBack = onBack,
        actions = {
            IconButton(enabled = online, onClick = { editing = RepoSetupEditTarget.New }) {
                Icon(Icons.Outlined.Add, contentDescription = "Add template")
            }
        },
    ) { m ->
        Box(m.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item {
                    Text(
                        "Templates of GitHub merge settings and branch rulesets. The default " +
                            "template is applied to newly created repositories.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                errorMessage?.let { item { AutopilotErrorRow(it) } }

                if (templates.isEmpty() && !isLoading) {
                    item { AutopilotEmptyState("No templates yet. Tap + to create one.") }
                }

                items(templates, key = { it.id }) { template ->
                    TemplateRow(
                        template = template,
                        enabled = online,
                        onEdit = { editing = RepoSetupEditTarget.Existing(template) },
                        onDelete = { deleteTarget = template },
                    )
                }
            }
            AutopilotLoadingOverlay(isLoading && templates.isEmpty())
        }
    }

    deleteTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete template?") },
            text = { Text("\"${target.name}\" will be removed.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try {
                            service.deleteRepoSetupTemplate(target.id)
                            reloadKey++
                        } catch (e: AutopilotException) {
                            errorMessage = e.message
                        }
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TemplateRow(
    template: RepoSetupTemplate,
    enabled: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = { if (enabled) onEdit() },
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(template.name, style = MaterialTheme.typography.bodyLarge)
                Text(
                    if (template.enabled) "Enabled" else "Disabled",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (template.isDefault) {
                AssistChip(onClick = {}, enabled = false, label = { Text("Default") })
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Outlined.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun RepoSetupEditor(
    target: RepoSetupEditTarget,
    service: AutopilotService,
    online: Boolean,
    onClose: () -> Unit,
    onSaved: () -> Unit,
) {
    val existing = (target as? RepoSetupEditTarget.Existing)?.template
    var isLoading by remember { mutableStateOf(true) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var schema by remember { mutableStateOf<JsonObject?>(null) }
    var uiSchema by remember { mutableStateOf<JsonObject?>(null) }

    LaunchedEffect(online) {
        if (!online) { isLoading = false; loadError = "Connect an online Mac to use Autopilot."; return@LaunchedEffect }
        isLoading = true
        loadError = null
        try {
            val envelope = service.repoSetupSchema()
            schema = envelope.schema as? JsonObject
            uiSchema = envelope.uiSchema as? JsonObject
        } catch (e: AutopilotException) {
            loadError = e.message
        } finally {
            isLoading = false
        }
    }

    val title = if (existing == null) "New Template" else "Edit Template"

    if (isLoading) {
        AutopilotScaffold(title, onClose) { m -> AutopilotLoadingOverlay(true, m.fillMaxSize()) }
        return
    }

    RepoSetupEditorLoaded(
        title = title,
        schema = schema,
        uiSchema = uiSchema,
        loadError = loadError,
        existing = existing,
        service = service,
        online = online,
        onClose = onClose,
        onSaved = onSaved,
    )
}

@Composable
private fun RepoSetupEditorLoaded(
    title: String,
    schema: JsonObject?,
    uiSchema: JsonObject?,
    loadError: String?,
    existing: RepoSetupTemplate?,
    service: AutopilotService,
    online: Boolean,
    onClose: () -> Unit,
    onSaved: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var enabled by remember { mutableStateOf(existing?.enabled ?: true) }
    var isDefault by remember { mutableStateOf(existing?.isDefault ?: false) }
    var rulesetText by remember {
        mutableStateOf(
            existing?.rulesetConfig?.let { RxJson.encodeToString(JsonElement.serializer(), it) } ?: ""
        )
    }
    var mergeFallbackText by remember {
        mutableStateOf(
            existing?.mergeSettings?.let { RxJson.encodeToString(JsonElement.serializer(), it) } ?: "{}"
        )
    }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    val formState = if (schema != null) {
        rememberJsonSchemaFormState(schema, existing?.mergeSettings)
    } else {
        null
    }

    fun save() {
        if (name.isBlank()) { errorMessage = "Name is required."; return }
        val mergeSettings: JsonElement = if (formState != null) {
            formState.submit() ?: return
        } else {
            runCatching { RxJson.parseToJsonElement(mergeFallbackText) }.getOrElse {
                errorMessage = "Merge settings JSON is invalid."
                return
            }
        }
        val ruleset: JsonElement? = if (rulesetText.isBlank()) {
            null
        } else {
            when (val r = validateRuleset(rulesetText)) {
                is RulesetResult.Ok -> r.value
                is RulesetResult.Error -> { errorMessage = r.message; return }
            }
        }
        val input = RepoSetupTemplateInput(
            name = name.trim(),
            enabled = enabled,
            isDefault = isDefault,
            mergeSettings = mergeSettings,
            rulesetConfig = ruleset,
        )
        isSaving = true
        errorMessage = null
        scope.launch {
            try {
                if (existing == null) service.createRepoSetupTemplate(input)
                else service.updateRepoSetupTemplate(existing.id, input)
                onSaved()
            } catch (e: AutopilotException) {
                errorMessage = e.message
            } finally {
                isSaving = false
            }
        }
    }

    AutopilotScaffold(
        title = title,
        onBack = onClose,
        actions = {
            TextButton(enabled = online && !isSaving && name.isNotBlank(), onClick = { save() }) {
                Text("Save")
            }
        },
    ) { m ->
        Column(
            m.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            loadError?.let { AutopilotErrorRow(it) }

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            ToggleRow("Enabled", enabled) { enabled = it }
            ToggleRow("Default for new repositories", isDefault) { isDefault = it }

            AutopilotSectionLabel("Merge Settings")
            if (formState != null && schema != null) {
                JsonSchemaForm(schema, uiSchema, formState)
                if (formState.showErrors) formState.errors.forEach { AutopilotErrorRow(it) }
            } else {
                Text(
                    "Form couldn't be rendered — edit raw JSON.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(
                    value = mergeFallbackText,
                    onValueChange = { mergeFallbackText = it },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 6,
                )
            }

            AutopilotSectionLabel("Branch Ruleset (optional)")
            Text(
                "Paste a GitHub ruleset JSON with name, target, enforcement, and rules.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = rulesetText,
                onValueChange = { rulesetText = it },
                modifier = Modifier.fillMaxWidth(),
                minLines = 5,
            )

            errorMessage?.let { AutopilotErrorRow(it) }
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

// MARK: - Ruleset validation (mirrors Swift GitHubRulesetSummary.validate)

private sealed interface RulesetResult {
    data class Ok(val value: JsonElement) : RulesetResult
    data class Error(val message: String) : RulesetResult
}

private fun validateRuleset(rawJSON: String): RulesetResult {
    if (rawJSON.isBlank()) return RulesetResult.Error("Ruleset JSON is empty.")
    val element = runCatching { RxJson.parseToJsonElement(rawJSON) }.getOrNull()
        ?: return RulesetResult.Error("Ruleset JSON is invalid.")
    val obj = element as? JsonObject ?: return RulesetResult.Error("Ruleset must be a JSON object.")
    val missing = buildList {
        if ((obj["name"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank()) add("name")
        if ((obj["target"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank()) add("target")
        if ((obj["enforcement"] as? JsonPrimitive)?.contentOrNull.isNullOrBlank()) add("enforcement")
        if (obj["rules"] !is JsonArray) add("rules")
    }
    return if (missing.isEmpty()) {
        RulesetResult.Ok(obj)
    } else {
        RulesetResult.Error("Ruleset is missing: ${missing.joinToString(", ")}")
    }
}
