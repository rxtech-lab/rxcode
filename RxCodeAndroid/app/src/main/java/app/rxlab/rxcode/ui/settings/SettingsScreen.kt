package app.rxlab.rxcode.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.automirrored.outlined.ArrowForwardIos
import androidx.compose.material.icons.outlined.DesktopMac
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Router
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.BuildConfig
import app.rxlab.rxcode.relay.RelayClient
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.store.PairedDesktop
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics

/**
 * Settings screen. Mirrors `MobileSettingsView` on iOS with the subsections
 * we can implement against the current Android sync proto:
 *
 * - Paired Macs (switch active / unpair, with active checkmark)
 * - Connection (relay URL + current websocket state as a colored chip)
 * - About (app version)
 *
 * Sub-screens for MCP servers, ACP clients, skills, run profiles, and remote
 * folder picker are still gated on `MobileSettingsSnapshot` flowing through
 * the Android sync proto — they'll plug into this scaffold as additional
 * sections once that lands.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: MobileState,
    viewModel: MobileAppState,
    onBack: () -> Unit,
    onPairNewMac: (() -> Unit)? = null,
) {
    val haptics = rememberHaptics()
    var unpairTarget by remember { mutableStateOf<PairedDesktop?>(null) }
    var showAutopilot by rememberSaveable { mutableStateOf(false) }

    if (showAutopilot) {
        app.rxlab.rxcode.ui.autopilot.AutopilotNavHost(
            app = viewModel,
            online = state.isPaired &&
                state.connectionState == RelayClient.ConnectionState.CONNECTED,
            onExit = { showAutopilot = false },
        )
        return
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // MARK: - Paired Macs
            item {
                SectionLabel("Paired Macs")
            }
            items(state.pairedDesktops, key = { it.id }) { desktop ->
                PairedDesktopCard(
                    desktop = desktop,
                    isActive = desktop.pubkeyHex == state.activeDesktopPubkey,
                    onSwitch = {
                        haptics.play(HapticEvent.Selection)
                        viewModel.switchActiveDesktop(desktop)
                    },
                    onUnpair = { unpairTarget = desktop },
                )
            }
            if (onPairNewMac != null) {
                item {
                    OutlinedButton(
                        onClick = {
                            haptics.play(HapticEvent.LightTap)
                            onPairNewMac()
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Outlined.Add, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Pair a new Mac")
                    }
                }
            }

            // MARK: - Connection
            item {
                SectionLabel("Connection")
            }
            item {
                ConnectionCard(
                    relayUrl = state.relayUrl,
                    connectionState = state.connectionState,
                    onReconnect = {
                        haptics.play(HapticEvent.LightTap)
                        viewModel.requestSnapshot("manual_reconnect")
                    },
                )
            }

            // MARK: - Desktop Configuration (Autopilot)
            if (state.isPaired) {
                item {
                    SectionLabel("Desktop Configuration")
                }
                item {
                    ElevatedCard(
                        modifier = Modifier.fillMaxWidth(),
                        onClick = {
                            haptics.play(HapticEvent.LightTap)
                            showAutopilot = true
                        },
                        colors = CardDefaults.elevatedCardColors(
                            containerColor = MaterialTheme.colorScheme.surfaceContainer,
                        ),
                    ) {
                        Row(
                            Modifier.padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(14.dp),
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.secondaryContainer,
                                contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                                modifier = Modifier.size(44.dp),
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(Icons.Outlined.Flight, contentDescription = null)
                                }
                            }
                            Column(Modifier.weight(1f)) {
                                Text(
                                    "Autopilot",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Text(
                                    "Automation, secrets, CI, docs, and releases",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                )
                            }
                            Icon(
                                Icons.AutoMirrored.Outlined.ArrowForwardIos,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(14.dp),
                            )
                        }
                    }
                }
            }

            // MARK: - About
            item {
                SectionLabel("About")
            }
            item {
                ElevatedCard(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.elevatedCardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceContainer,
                    ),
                ) {
                    Row(
                        Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.surfaceContainerHighest,
                            modifier = Modifier.size(44.dp),
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(Icons.Outlined.Info, contentDescription = null)
                            }
                        }
                        Column(Modifier.weight(1f)) {
                            Text(
                                "RxCode for Android",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                "Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }

    // Confirm before unpairing — the iOS app shows a destructive confirm too.
    unpairTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { unpairTarget = null },
            icon = {
                Icon(
                    Icons.Outlined.Delete,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                )
            },
            title = { Text("Unpair ${target.displayName}?") },
            text = {
                Text(
                    "This device will no longer sync with this Mac. " +
                        "You can pair again from the Mac's RxCode Settings → Mobile menu.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    haptics.play(HapticEvent.HeavyImpact)
                    viewModel.removeDesktop(target)
                    unpairTarget = null
                }) {
                    Text("Unpair", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { unpairTarget = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = 4.dp, bottom = 4.dp),
    )
}

@Composable
private fun PairedDesktopCard(
    desktop: PairedDesktop,
    isActive: Boolean,
    onSwitch: () -> Unit,
    onUnpair: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = { if (!isActive) onSwitch() },
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (isActive) MaterialTheme.colorScheme.primaryContainer
            else MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Surface(
                shape = CircleShape,
                color = if (isActive) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.secondary,
                contentColor = if (isActive) MaterialTheme.colorScheme.onPrimary
                else MaterialTheme.colorScheme.onSecondary,
                modifier = Modifier.size(44.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.DesktopMac, contentDescription = null)
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    desktop.displayName,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                desktop.relayUrl?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                    )
                }
            }
            if (isActive) {
                Icon(
                    Icons.Outlined.CheckCircle,
                    contentDescription = "Active",
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
            IconButton(onClick = onUnpair) {
                Icon(
                    Icons.Outlined.Delete,
                    contentDescription = "Unpair",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ConnectionCard(
    relayUrl: String,
    connectionState: RelayClient.ConnectionState,
    onReconnect: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Column(
            Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surfaceContainerHighest,
                    modifier = Modifier.size(40.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Outlined.Router, contentDescription = null)
                    }
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        "Relay",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        relayUrl.ifBlank { "—" },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
                ConnectionStateChip(connectionState)
            }
            if (connectionState == RelayClient.ConnectionState.DISCONNECTED) {
                OutlinedButton(
                    onClick = onReconnect,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Try to reconnect") }
            }
        }
    }
}

@Composable
private fun ConnectionStateChip(state: RelayClient.ConnectionState) {
    val (label, dotColor, container, content) = when (state) {
        RelayClient.ConnectionState.CONNECTED -> Quadruple(
            "Connected",
            Color(0xFF34C759),
            MaterialTheme.colorScheme.secondaryContainer,
            MaterialTheme.colorScheme.onSecondaryContainer,
        )
        RelayClient.ConnectionState.CONNECTING -> Quadruple(
            "Connecting",
            MaterialTheme.colorScheme.primary,
            MaterialTheme.colorScheme.primaryContainer,
            MaterialTheme.colorScheme.onPrimaryContainer,
        )
        RelayClient.ConnectionState.RECONNECTING -> Quadruple(
            "Reconnecting",
            MaterialTheme.colorScheme.tertiary,
            MaterialTheme.colorScheme.tertiaryContainer,
            MaterialTheme.colorScheme.onTertiaryContainer,
        )
        RelayClient.ConnectionState.DISCONNECTED -> Quadruple(
            "Offline",
            MaterialTheme.colorScheme.error,
            MaterialTheme.colorScheme.errorContainer,
            MaterialTheme.colorScheme.onErrorContainer,
        )
    }
    AssistChip(
        onClick = {},
        enabled = false,
        label = { Text(label) },
        leadingIcon = {
            Box(
                Modifier
                    .size(8.dp)
                    .background(dotColor, CircleShape)
            )
        },
        colors = AssistChipDefaults.assistChipColors(
            disabledContainerColor = container,
            disabledLabelColor = content,
            disabledLeadingIconContentColor = content,
        ),
    )
}

/**
 * Tiny ad-hoc holder so `ConnectionStateChip` can return four pieces of
 * styling from its `when` mapping without an inline class boilerplate.
 * `data class` synthesizes the `componentN` operators automatically.
 */
private data class Quadruple<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)
