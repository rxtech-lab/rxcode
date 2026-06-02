package app.rxlab.rxcode.ui.mcp

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MobileMCPKeyValue
import app.rxlab.rxcode.proto.MobileMCPServer
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.autopilot.AutopilotEmptyState
import app.rxlab.rxcode.ui.autopilot.AutopilotErrorRow
import app.rxlab.rxcode.ui.autopilot.AutopilotScaffold
import app.rxlab.rxcode.ui.autopilot.AutopilotSectionLabel

/** Local edit target: either adding a new server or editing an existing one. */
private sealed interface McpForm {
    data object Add : McpForm
    data class Edit(val server: MobileMCPServer) : McpForm
}

/**
 * Manage the paired desktop's global MCP servers. 1:1 with iOS
 * `MobileMCPServersView`: list with enable toggles + remove, plus an add/edit
 * form that the desktop upserts by name.
 */
@Composable
fun McpServersScreen(
    app: MobileAppState,
    online: Boolean,
    onExit: () -> Unit,
) {
    val state by app.state.collectAsState()
    var form by remember { mutableStateOf<McpForm?>(null) }
    var pendingRemoval by remember { mutableStateOf<MobileMCPServer?>(null) }

    LaunchedEffect(Unit) {
        if (state.mcpServers.isEmpty()) app.requestMCPConfig()
    }

    form?.let { target ->
        BackHandler { form = null }
        McpServerFormScreen(
            existing = (target as? McpForm.Edit)?.server,
            online = online,
            onCancel = { form = null },
            onSave = { server ->
                app.addMCPServer(server)
                form = null
            },
        )
        return
    }

    AutopilotScaffold(
        title = "MCP Servers",
        onBack = onExit,
        actions = {
            IconButton(onClick = { app.requestMCPConfig() }, enabled = online) {
                Icon(Icons.Outlined.Refresh, contentDescription = "Refresh")
            }
            IconButton(onClick = { form = McpForm.Add }, enabled = online) {
                Icon(Icons.Outlined.Add, contentDescription = "Add MCP Server")
            }
        },
    ) { modifier ->
        LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            state.mcpConfigError?.let { item { AutopilotErrorRow(it) } }
            state.lastMCPError?.let { item { AutopilotErrorRow(it) } }

            if (state.mcpServers.isEmpty()) {
                item {
                    if (state.mcpConfigLoading) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp))
                            Text("Loading…", style = MaterialTheme.typography.bodyMedium)
                        }
                    } else if (state.mcpConfigError == null) {
                        AutopilotEmptyState("No MCP servers configured. Tap + to add one.")
                    }
                }
            } else {
                items(state.mcpServers, key = { it.name }) { server ->
                    McpServerRow(
                        server = server,
                        inFlight = state.inFlightMCPMutations.contains(server.name),
                        online = online,
                        onEdit = { form = McpForm.Edit(server) },
                        onToggle = { app.setMCPServerEnabled(server.name, it) },
                        onRemove = { pendingRemoval = server },
                    )
                }
            }
        }
    }

    pendingRemoval?.let { server ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text("Remove MCP server?") },
            text = { Text("This removes ${server.name} from your Mac's global MCP configuration.") },
            confirmButton = {
                TextButton(onClick = {
                    app.removeMCPServer(server.name)
                    pendingRemoval = null
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingRemoval = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun McpServerRow(
    server: MobileMCPServer,
    inFlight: Boolean,
    online: Boolean,
    onEdit: () -> Unit,
    onToggle: (Boolean) -> Unit,
    onRemove: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = { if (online) onEdit() },
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        server.name,
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    AssistChip(
                        onClick = {},
                        enabled = false,
                        label = { Text(server.transport.uppercase(), style = MaterialTheme.typography.labelSmall) },
                        colors = AssistChipDefaults.assistChipColors(
                            disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                            disabledLabelColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                    )
                }
                if (server.endpoint.isNotEmpty()) {
                    Text(
                        server.endpoint,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (inFlight) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp))
            } else {
                Switch(
                    checked = server.isGloballyEnabled,
                    onCheckedChange = onToggle,
                    enabled = online,
                )
            }
            IconButton(onClick = onRemove) {
                Icon(
                    Icons.Outlined.Delete,
                    contentDescription = "Remove",
                    tint = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

/** Mutable holder for a key/value form row so edits recompose in place. */
private class KeyValueDraft(key: String, value: String) {
    var key by mutableStateOf(key)
    var value by mutableStateOf(value)
}

@Composable
private fun McpServerFormScreen(
    existing: MobileMCPServer?,
    online: Boolean,
    onCancel: () -> Unit,
    onSave: (MobileMCPServer) -> Unit,
) {
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var transport by remember { mutableStateOf(existing?.transport ?: "stdio") }
    var command by remember { mutableStateOf(existing?.command ?: "") }
    var url by remember { mutableStateOf(existing?.url ?: "") }
    val args = remember { mutableStateListOf<String>().apply { existing?.args?.let { addAll(it) } } }
    val env = remember {
        mutableStateListOf<KeyValueDraft>().apply {
            existing?.env?.forEach { add(KeyValueDraft(it.key, it.value)) }
        }
    }
    val headers = remember {
        mutableStateListOf<KeyValueDraft>().apply {
            existing?.headers?.forEach { add(KeyValueDraft(it.key, it.value)) }
        }
    }

    val isStdio = transport == "stdio"
    val canSave = name.trim().isNotEmpty() &&
        (if (isStdio) command.trim().isNotEmpty() else url.trim().isNotEmpty()) &&
        online

    AutopilotScaffold(
        title = if (existing == null) "Add MCP Server" else "Edit MCP Server",
        onBack = onCancel,
        actions = {
            TextButton(
                enabled = canSave,
                onClick = {
                    val cleanArgs = args.map { it.trim() }.filter { it.isNotEmpty() }
                    val cleanEnv = env.mapNotNull { kv ->
                        kv.key.trim().takeIf { it.isNotEmpty() }?.let { MobileMCPKeyValue(it, kv.value) }
                    }
                    val cleanHeaders = headers.mapNotNull { kv ->
                        kv.key.trim().takeIf { it.isNotEmpty() }?.let { MobileMCPKeyValue(it, kv.value) }
                    }
                    val trimmedCommand = command.trim()
                    val trimmedURL = url.trim()
                    val endpoint = if (isStdio) {
                        (listOf(trimmedCommand) + cleanArgs).filter { it.isNotEmpty() }.joinToString(" ")
                    } else {
                        trimmedURL
                    }
                    onSave(
                        MobileMCPServer(
                            name = name.trim(),
                            transport = transport,
                            url = if (isStdio) null else trimmedURL,
                            command = if (isStdio) trimmedCommand else null,
                            args = if (isStdio) cleanArgs else emptyList(),
                            env = if (isStdio) cleanEnv else emptyList(),
                            headers = if (isStdio) emptyList() else cleanHeaders,
                            isGloballyEnabled = existing?.isGloballyEnabled ?: true,
                            endpoint = endpoint,
                        )
                    )
                },
            ) { Text("Save") }
        },
    ) { modifier ->
        LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                AutopilotSectionLabel("Server")
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Name") },
                    singleLine = true,
                    enabled = existing == null,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                AutopilotSectionLabel("Transport")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("stdio" to "stdio", "http" to "HTTP", "sse" to "SSE").forEach { (value, label) ->
                        FilterChip(
                            selected = transport == value,
                            onClick = { transport = value },
                            label = { Text(label) },
                        )
                    }
                }
            }

            if (isStdio) {
                item {
                    AutopilotSectionLabel("Command")
                    OutlinedTextField(
                        value = command,
                        onValueChange = { command = it },
                        label = { Text("Command") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                item { AutopilotSectionLabel("Arguments") }
                items(args.size) { index ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        OutlinedTextField(
                            value = args[index],
                            onValueChange = { args[index] = it },
                            label = { Text("Argument") },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(onClick = { args.removeAt(index) }) {
                            Icon(Icons.Outlined.Delete, contentDescription = "Remove argument")
                        }
                    }
                }
                item {
                    TextButton(onClick = { args.add("") }) {
                        Icon(Icons.Outlined.Add, contentDescription = null)
                        Text("Add Argument")
                    }
                }
                keyValueEditor("Environment Variables", "Add Variable", env)
            } else {
                item {
                    AutopilotSectionLabel("Endpoint")
                    OutlinedTextField(
                        value = url,
                        onValueChange = { url = it },
                        label = { Text("URL") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                keyValueEditor("Headers", "Add Header", headers)
            }
        }
    }
}

/** Renders a titled list of editable key/value rows with add/remove. */
private fun androidx.compose.foundation.lazy.LazyListScope.keyValueEditor(
    title: String,
    addLabel: String,
    items: androidx.compose.runtime.snapshots.SnapshotStateList<KeyValueDraft>,
) {
    item { AutopilotSectionLabel(title) }
    items(items.size) { index ->
        val draft = items[index]
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = draft.key,
                onValueChange = { draft.key = it },
                label = { Text("Key") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = draft.value,
                onValueChange = { draft.value = it },
                label = { Text("Value") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = { items.removeAt(index) }) {
                Icon(Icons.Outlined.Delete, contentDescription = "Remove")
            }
        }
    }
    item {
        TextButton(onClick = { items.add(KeyValueDraft("", "")) }) {
            Icon(Icons.Outlined.Add, contentDescription = null)
            Text(addLabel)
        }
    }
}
