package app.rxlab.rxcode.ui.sync

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.DesktopMac
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.store.PairedDesktop
import kotlinx.coroutines.delay

/**
 * Cold-launch splash shown until the desktop returns the first snapshot.
 * Mirrors iOS `SyncLoadingView`: shows a spinner with a friendly message
 * for the first ~15 seconds, then switches to a timed-out state with a
 * retry button, a list of paired desktops to switch between, and a CTA to
 * pair a new Mac. Mirrors the iOS UX so users can recover from a sleeping
 * desktop without restarting the app.
 */
@Composable
fun SyncLoadingView(
    isTimedOut: Boolean,
    pairedDesktops: List<PairedDesktop>,
    activeDesktopPubkey: String,
    onRetry: () -> Unit,
    onSelectDesktop: (PairedDesktop) -> Unit,
    onPairNewDesktop: () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 24.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            HeroIcon(isTimedOut = isTimedOut)
            Spacer(Modifier.height(20.dp))
            Text(
                if (isTimedOut) "Couldn't reach your Mac" else "Connecting to your Mac",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                if (isTimedOut) {
                    "Your Mac may be sleeping or offline. Try again or pair a new Mac to keep working."
                } else {
                    "Waiting for the first snapshot to arrive."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )

            Spacer(Modifier.height(24.dp))

            if (!isTimedOut) {
                IndeterminateProgress()
                Spacer(Modifier.height(16.dp))
                // Pulse the dots after a few seconds to reassure the user we
                // haven't given up.
                var seconds by remember { mutableStateOf(0) }
                LaunchedEffect(Unit) {
                    while (true) {
                        delay(1000)
                        seconds += 1
                    }
                }
                if (seconds in 6..14) {
                    Text(
                        "Still waiting…",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            } else {
                Button(onClick = onRetry, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.Refresh, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Retry")
                }
            }

            if (pairedDesktops.size > 1) {
                Spacer(Modifier.height(28.dp))
                Text(
                    "Switch to another Mac",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 8.dp),
                )
                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(pairedDesktops, key = { it.id }) { desktop ->
                        DesktopRow(
                            desktop = desktop,
                            isActive = desktop.pubkeyHex == activeDesktopPubkey,
                            onClick = { onSelectDesktop(desktop) },
                        )
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
            OutlinedButton(
                onClick = onPairNewDesktop,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Outlined.Add, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Pair a new Mac")
            }
        }
    }
}

@Composable
private fun HeroIcon(isTimedOut: Boolean) {
    Surface(
        shape = CircleShape,
        color = if (isTimedOut) MaterialTheme.colorScheme.errorContainer
        else MaterialTheme.colorScheme.primaryContainer,
        contentColor = if (isTimedOut) MaterialTheme.colorScheme.onErrorContainer
        else MaterialTheme.colorScheme.onPrimaryContainer,
        modifier = Modifier.size(96.dp),
        tonalElevation = 4.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                if (isTimedOut) Icons.Outlined.CloudOff else Icons.Outlined.DesktopMac,
                contentDescription = null,
                modifier = Modifier.size(44.dp),
            )
        }
    }
}

@Composable
private fun IndeterminateProgress() {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun DesktopRow(
    desktop: PairedDesktop,
    isActive: Boolean,
    onClick: () -> Unit,
) {
    ElevatedCard(
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
        colors = CardDefaults.elevatedCardColors(
            containerColor = if (isActive) MaterialTheme.colorScheme.primaryContainer
            else MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surfaceContainerHighest,
                modifier = Modifier.size(36.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.DesktopMac, contentDescription = null)
                }
            }
            Column(Modifier.weight(1f)) {
                Text(
                    desktop.displayName,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                desktop.relayUrl?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
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
        }
    }
}
