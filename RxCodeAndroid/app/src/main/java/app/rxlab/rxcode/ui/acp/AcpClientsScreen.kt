package app.rxlab.rxcode.ui.acp

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MobileACPClient
import app.rxlab.rxcode.proto.MobileACPRegistryAgent
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.autopilot.AutopilotEmptyState
import app.rxlab.rxcode.ui.autopilot.AutopilotErrorRow
import app.rxlab.rxcode.ui.autopilot.AutopilotScaffold
import app.rxlab.rxcode.ui.autopilot.AutopilotSectionLabel
import coil.compose.AsyncImage

/**
 * Manage ACP agent clients on the paired desktop. 1:1 with iOS
 * `MobileACPClientsView`: toggle/remove installed clients and install new ones
 * from the agentclientprotocol.com registry.
 */
@Composable
fun AcpClientsScreen(
    app: MobileAppState,
    online: Boolean,
    onExit: () -> Unit,
) {
    val state by app.state.collectAsState()
    var pendingUninstall by remember { mutableStateOf<MobileACPClient?>(null) }

    LaunchedEffect(online, state.activeDesktopPubkey, state.hasReceivedInitialSnapshot) {
        if (online &&
            state.hasReceivedInitialSnapshot &&
            !state.acpRegistryLoading &&
            state.acpRegistryAgents.isEmpty() &&
            state.acpInstalledClients.isEmpty()
        ) {
            app.requestACPRegistry()
        }
    }

    AutopilotScaffold(
        title = "Agent Clients",
        onBack = onExit,
        actions = {
            if (state.acpRegistryLoading) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp))
            } else {
                IconButton(onClick = { app.requestACPRegistry(forceRefresh = true) }, enabled = online) {
                    Icon(Icons.Outlined.Refresh, contentDescription = "Refresh")
                }
            }
        },
    ) { modifier ->
        val available = state.acpRegistryAgents.filter { !it.isInstalled }
        LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            state.acpRegistryError?.let { item { AutopilotErrorRow(it) } }
            state.lastACPError?.let { item { AutopilotErrorRow(it) } }

            if (online && !state.hasReceivedInitialSnapshot) {
                item {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp))
                        Text("Waiting for Mac sync…", style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }

            if (state.acpInstalledClients.isNotEmpty()) {
                item { AutopilotSectionLabel("Installed") }
                items(state.acpInstalledClients, key = { it.id }) { client ->
                    InstalledClientRow(
                        client = client,
                        inFlight = state.inFlightACPMutations.contains(client.id),
                        online = online,
                        onToggle = { app.setACPClientEnabled(client.id, it) },
                        onRemove = { pendingUninstall = client },
                    )
                }
            }

            if (available.isNotEmpty()) {
                item { AutopilotSectionLabel("Available in Registry") }
                items(available, key = { it.id }) { agent ->
                    RegistryAgentRow(
                        agent = agent,
                        inFlight = state.inFlightACPMutations.contains(agent.id),
                        online = online,
                        onInstall = { app.installACPAgent(agent.id) },
                    )
                }
            } else if (state.hasReceivedInitialSnapshot &&
                state.acpInstalledClients.isEmpty() &&
                !state.acpRegistryLoading &&
                state.acpRegistryError == null
            ) {
                item { AutopilotEmptyState("No agents found.") }
            }
        }
    }

    pendingUninstall?.let { client ->
        AlertDialog(
            onDismissRequest = { pendingUninstall = null },
            title = { Text("Remove agent?") },
            text = { Text("This removes ${client.displayName} and its downloaded binary from your Mac.") },
            confirmButton = {
                TextButton(onClick = {
                    app.uninstallACPClient(client.id)
                    pendingUninstall = null
                }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingUninstall = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun AgentIcon(iconURL: String?) {
    // Tint the logo to match the title text color (1:1 with iOS template-tinting),
    // so monochrome ACP SVG logos render in the same color as the agent name.
    val titleColor = MaterialTheme.colorScheme.onSurface
    if (iconURL.isNullOrEmpty()) {
        Icon(
            Icons.Outlined.Memory,
            contentDescription = null,
            tint = titleColor,
            modifier = Modifier.size(28.dp),
        )
    } else {
        AsyncImage(
            model = iconURL,
            contentDescription = null,
            colorFilter = ColorFilter.tint(titleColor),
            modifier = Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(6.dp)),
        )
    }
}

@Composable
private fun InstalledClientRow(
    client: MobileACPClient,
    inFlight: Boolean,
    online: Boolean,
    onToggle: (Boolean) -> Unit,
    onRemove: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AgentIcon(client.iconURL)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(client.displayName, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    "${client.launchKind} · ${client.modelCount} model${if (client.modelCount == 1) "" else "s"}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (inFlight) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp))
            } else {
                Switch(checked = client.enabled, onCheckedChange = onToggle, enabled = online)
            }
            IconButton(onClick = onRemove) {
                Icon(Icons.Outlined.Delete, contentDescription = "Remove", tint = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun RegistryAgentRow(
    agent: MobileACPRegistryAgent,
    inFlight: Boolean,
    online: Boolean,
    onInstall: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            AgentIcon(agent.iconURL)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(agent.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        agent.version,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (agent.summary.isNotEmpty()) {
                    Text(
                        agent.summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                distributionLabel(agent)?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (inFlight) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp))
                    Text("Installing…", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                Button(onClick = onInstall, enabled = online, contentPadding = ButtonDefaults.ContentPadding) {
                    Text("Install")
                }
            }
        }
    }
}

private fun distributionLabel(agent: MobileACPRegistryAgent): String? {
    val kinds = buildList {
        if (agent.hasBinary) add("binary")
        if (agent.hasNpx) add("npx")
        if (agent.hasUvx) add("uvx")
    }
    return kinds.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}
