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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForwardIos
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.LocalOffer
import androidx.compose.material.icons.outlined.Loop
import androidx.compose.material.icons.outlined.MenuBook
import androidx.compose.material.icons.outlined.PersonOutline
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.VpnKey
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.AutopilotAccountStatus
import app.rxlab.rxcode.state.AutopilotException
import app.rxlab.rxcode.state.AutopilotService
import coil.compose.AsyncImage

/**
 * Autopilot hub — mirrors iOS `MobileAutopilotView`. Shows the rxlab account
 * status, an offline notice when the Mac is unreachable, and navigation into
 * the Configuration (Automation, Repo Setup) and Repositories (Secrets, CI,
 * Docs, Releases) sub-features.
 */
@Composable
fun AutopilotHubScreen(
    service: AutopilotService,
    online: Boolean,
    nav: AutopilotNav,
) {
    var account by remember { mutableStateOf<AutopilotAccountStatus?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(online) {
        if (!online) return@LaunchedEffect
        isLoading = true
        loadError = null
        try {
            account = service.accountStatus()
        } catch (e: AutopilotException) {
            loadError = e.message
        } finally {
            isLoading = false
        }
    }

    val signedIn = account?.isSignedIn == true

    AutopilotScaffold(title = "Autopilot", onBack = { nav.pop() }) { modifier ->
        Box(modifier.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (!online) {
                    item { OfflineNotice() }
                }

                item { AccountCard(account, isLoading) }

                if (signedIn) {
                    item { AutopilotSectionLabel("Configuration") }
                    item {
                        HubRow("Automation", Icons.Outlined.AutoAwesome, online) {
                            nav.push(AutopilotRoute.Automation)
                        }
                    }
                    item {
                        HubRow("Repo Setup", Icons.Outlined.Tune, online) {
                            nav.push(AutopilotRoute.RepoSetup)
                        }
                    }

                    item { AutopilotSectionLabel("Repositories") }
                    item {
                        HubRow("Secrets", Icons.Outlined.VpnKey, online) {
                            nav.push(AutopilotRoute.Secrets)
                        }
                    }
                    item {
                        HubRow("CI Auto-Update", Icons.Outlined.Loop, online) {
                            nav.push(AutopilotRoute.Ci)
                        }
                    }
                    item {
                        HubRow("Documentation", Icons.Outlined.MenuBook, online) {
                            nav.push(AutopilotRoute.Docs)
                        }
                    }
                    item {
                        HubRow("Releases", Icons.Outlined.LocalOffer, online) {
                            nav.push(AutopilotRoute.Release)
                        }
                    }
                } else if (!isLoading && loadError == null && online) {
                    item {
                        Text(
                            "Sign in with rxlab on your Mac to enable Autopilot.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                loadError?.let { item { AutopilotErrorRow(it) } }
            }
        }
    }
}

@Composable
private fun OfflineNotice() {
    ElevatedCard(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.WifiOff, contentDescription = null, tint = AutopilotWarning)
            Column {
                Text("Mac offline", style = MaterialTheme.typography.titleSmall)
                Text(
                    "Connect to an online Mac to manage Autopilot.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun AccountCard(account: AutopilotAccountStatus?, isLoading: Boolean) {
    ElevatedCard(
        Modifier.fillMaxWidth(),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            when {
                isLoading && account == null -> {
                    CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                    Text(
                        "Checking account…",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                account?.isSignedIn == true -> {
                    val avatar = account.avatarURL
                    Surface(shape = CircleShape, modifier = Modifier.size(36.dp)) {
                        if (avatar != null) {
                            AsyncImage(model = avatar, contentDescription = null)
                        } else {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(Icons.Outlined.PersonOutline, contentDescription = null)
                            }
                        }
                    }
                    Column(Modifier.weight(1f)) {
                        Text(
                            account.name ?: "Signed in",
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                        account.email?.let {
                            Text(
                                it,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                else -> {
                    Icon(Icons.Outlined.PersonOutline, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(
                        "Not signed in",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun HubRow(
    title: String,
    icon: ImageVector,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = { if (enabled) onClick() },
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f),
            )
            Icon(
                Icons.AutoMirrored.Outlined.ArrowForwardIos,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}
