package app.rxlab.rxcode.ui.autopilot

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.AutopilotService
import app.rxlab.rxcode.ui.jsonschemaform.JsonSchemaForm
import app.rxlab.rxcode.ui.jsonschemaform.rememberJsonSchemaFormState
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * Automation settings — mirrors iOS `MobileAutomationView`. Renders the
 * desktop-supplied JSON Schema as a form (falling back to a raw JSON editor
 * when the schema can't be rendered), then saves the values back.
 */
@Composable
fun AutomationScreen(
    service: AutopilotService,
    online: Boolean,
    onBack: () -> Unit,
) {
    var isLoading by remember { mutableStateOf(true) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var schema by remember { mutableStateOf<JsonObject?>(null) }
    var uiSchema by remember { mutableStateOf<JsonObject?>(null) }
    var values by remember { mutableStateOf<JsonElement?>(null) }
    var reloadKey by remember { mutableStateOf(0) }

    LaunchedEffect(online, reloadKey) {
        if (!online) {
            isLoading = false
            loadError = "Connect an online Mac to use Autopilot."
            return@LaunchedEffect
        }
        isLoading = true
        loadError = null
        try {
            val envelope = service.automationSchema()
            schema = envelope.schema as? JsonObject
            uiSchema = envelope.uiSchema as? JsonObject
            values = service.automationValues().values
        } catch (e: AutopilotException) {
            loadError = e.message
        } finally {
            isLoading = false
        }
    }

    when {
        isLoading -> AutopilotScaffold("Automation", onBack) { m ->
            AutopilotLoadingOverlay(true, m.fillMaxSize())
        }
        loadError != null -> AutopilotScaffold("Automation", onBack) { m ->
            Column(m.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                AutopilotErrorRow(loadError!!)
                TextButton(onClick = { reloadKey++ }) { Text("Retry") }
            }
        }
        schema != null -> AutomationLoaded(
            schema = schema!!,
            uiSchema = uiSchema,
            existing = values,
            service = service,
            online = online,
            onBack = onBack,
        )
        else -> AutomationFallback(
            initial = values,
            service = service,
            online = online,
            onBack = onBack,
        )
    }
}

@Composable
private fun AutomationLoaded(
    schema: JsonObject,
    uiSchema: JsonObject?,
    existing: JsonElement?,
    service: AutopilotService,
    online: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val formState = rememberJsonSchemaFormState(schema, existing)
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var savedMessage by remember { mutableStateOf<String?>(null) }

    AutopilotScaffold(
        title = "Automation",
        onBack = onBack,
        actions = {
            TextButton(
                enabled = online && !isSaving,
                onClick = {
                    val obj = formState.submit() ?: return@TextButton
                    isSaving = true
                    errorMessage = null
                    savedMessage = null
                    scope.launch {
                        try {
                            service.saveAutomationValues(obj)
                            savedMessage = "Saved."
                        } catch (e: AutopilotException) {
                            errorMessage = e.message
                        } finally {
                            isSaving = false
                        }
                    }
                },
            ) { Text("Save") }
        },
    ) { m ->
        Column(
            m.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            JsonSchemaForm(schema, uiSchema, formState)
            if (formState.showErrors) {
                formState.errors.forEach { AutopilotErrorRow(it) }
            }
            errorMessage?.let { AutopilotErrorRow(it) }
            savedMessage?.let { AutopilotSuccessRow(it) }
        }
    }
}

@Composable
private fun AutomationFallback(
    initial: JsonElement?,
    service: AutopilotService,
    online: Boolean,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var text by remember {
        mutableStateOf(initial?.let { RxJson.encodeToString(JsonElement.serializer(), it) } ?: "{}")
    }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var savedMessage by remember { mutableStateOf<String?>(null) }

    AutopilotScaffold(
        title = "Automation",
        onBack = onBack,
        actions = {
            TextButton(
                enabled = online && !isSaving,
                onClick = {
                    val parsed = runCatching { RxJson.parseToJsonElement(text) }.getOrNull()
                    if (parsed == null) {
                        errorMessage = "Invalid JSON."
                        return@TextButton
                    }
                    isSaving = true
                    errorMessage = null
                    savedMessage = null
                    scope.launch {
                        try {
                            service.saveAutomationValues(parsed)
                            savedMessage = "Saved."
                        } catch (e: AutopilotException) {
                            errorMessage = e.message
                        } finally {
                            isSaving = false
                        }
                    }
                },
            ) { Text("Save") }
        },
    ) { m ->
        Column(
            m.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "This settings form couldn't be rendered. Edit the raw JSON instead.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(),
                minLines = 12,
            )
            if (isSaving) CircularProgressIndicator(Modifier.padding(top = 4.dp))
            errorMessage?.let { AutopilotErrorRow(it) }
            savedMessage?.let { AutopilotSuccessRow(it) }
        }
    }
}
