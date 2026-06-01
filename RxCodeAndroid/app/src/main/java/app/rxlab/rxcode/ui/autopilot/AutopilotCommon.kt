package app.rxlab.rxcode.ui.autopilot

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/** Warm orange used for inline warnings/errors, matching iOS `.orange`. */
val AutopilotWarning = Color(0xFFE8910C)

/** Success green, matching iOS `.green`. */
val AutopilotSuccess = Color(0xFF34C759)

/**
 * Standard chrome for an autopilot sub-screen: a top app bar with a back
 * button plus optional trailing [actions]. Disables interaction when offline
 * is handled by callers (they gate buttons), matching the iOS `.disabled`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutopilotScaffold(
    title: String,
    onBack: () -> Unit,
    actions: @Composable () -> Unit = {},
    content: @Composable (Modifier) -> Unit,
) {
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = { actions() },
            )
        },
    ) { padding ->
        content(Modifier.padding(padding))
    }
}

/** Centered loading indicator shown over a screen on its initial fetch only. */
@Composable
fun AutopilotLoadingOverlay(
    isLoading: Boolean,
    modifier: Modifier = Modifier,
    title: String = "Loading…",
) {
    AnimatedVisibility(visible = isLoading) {
        Box(
            modifier
                .fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.9f),
                modifier = Modifier.fillMaxSize(),
            ) {
                Column(
                    Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator()
                    Text(
                        title,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 12.dp),
                    )
                }
            }
        }
    }
}

/** Inline orange warning row used for `errorMessage` surfaces. */
@Composable
fun AutopilotErrorRow(message: String, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Outlined.WarningAmber,
            contentDescription = null,
            tint = AutopilotWarning,
            modifier = Modifier.size(18.dp),
        )
        Text(message, style = MaterialTheme.typography.bodySmall, color = AutopilotWarning)
    }
}

/** Inline green success row used for `statusMessage` surfaces. */
@Composable
fun AutopilotSuccessRow(message: String, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Outlined.CheckCircle,
            contentDescription = null,
            tint = AutopilotSuccess,
            modifier = Modifier.size(18.dp),
        )
        Text(message, style = MaterialTheme.typography.bodySmall, color = AutopilotSuccess)
    }
}

/** Small section header label, matching the look of `SettingsScreen`. */
@Composable
fun AutopilotSectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = modifier.padding(start = 4.dp, top = 4.dp, bottom = 4.dp),
    )
}

@Composable
fun AutopilotEmptyState(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.padding(vertical = 8.dp),
    )
}
