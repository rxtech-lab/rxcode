package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Construction
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Stop
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MobileRunTaskSnapshot
import app.rxlab.rxcode.proto.RunProfile
import app.rxlab.rxcode.proto.RunProfileType
import java.util.UUID

/**
 * Bottom sheet listing run profiles + recent tasks for a project. Mirrors the
 * iOS `MobileRunProfilesView` layout: a "Runs" section for task snapshots and
 * a "Profiles" section with Run/Stop buttons inline. Tapping a profile row
 * opens the editor; the "+" button creates a new bash profile.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RunProfilesSheet(
    profiles: List<RunProfile>,
    tasks: List<MobileRunTaskSnapshot>,
    onRun: (RunProfile) -> Unit,
    onStop: (MobileRunTaskSnapshot) -> Unit,
    onEdit: (RunProfile) -> Unit,
    onDelete: (RunProfile) -> Unit,
    onCreate: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val runningByProfile = remember(tasks) {
        tasks.filter { it.isRunning }.associateBy { it.profileId }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    "Run profiles",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                FilledIconButton(onClick = onCreate, modifier = Modifier.size(40.dp)) {
                    Icon(Icons.Outlined.Add, contentDescription = "Create profile")
                }
            }

            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val activeTasks = tasks.filter { it.isRunning }
                if (activeTasks.isNotEmpty()) {
                    item("runs-header") { SectionHeader("Active runs") }
                    items(activeTasks, key = { "task-${it.taskId}" }) { task ->
                        ActiveTaskRow(task = task, onStop = { onStop(task) })
                    }
                    item("divider") {
                        HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    }
                }

                item("profiles-header") { SectionHeader("Profiles") }
                if (profiles.isEmpty()) {
                    item("empty") {
                        Surface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(12.dp),
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                        ) {
                            Text(
                                "No profiles yet. Tap + to add a bash run profile.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(16.dp),
                            )
                        }
                    }
                } else {
                    items(profiles, key = { it.id }) { profile ->
                        ProfileRow(
                            profile = profile,
                            runningTask = runningByProfile[profile.id],
                            onRun = { onRun(profile) },
                            onStop = { task -> onStop(task) },
                            onEdit = { onEdit(profile) },
                            onDelete = { onDelete(profile) },
                        )
                    }
                }
                item("tail-gap") { Spacer(Modifier.height(20.dp)) }
            }
        }
    }
}

@Composable
private fun SectionHeader(label: String) {
    Text(
        label.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(top = 4.dp, bottom = 2.dp),
    )
}

@Composable
private fun ProfileRow(
    profile: RunProfile,
    runningTask: MobileRunTaskSnapshot?,
    onRun: () -> Unit,
    onStop: (MobileRunTaskSnapshot) -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onEdit),
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(
                shape = CircleShape,
                color = profile.type.tint().copy(alpha = 0.15f),
                modifier = Modifier.size(36.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        profile.type.icon(),
                        contentDescription = null,
                        tint = profile.type.tint(),
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    profile.name.ifBlank { "Untitled" },
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    profile.subtitle(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
            if (runningTask != null) {
                FilledIconButton(
                    onClick = { onStop(runningTask) },
                    colors = IconButtonDefaults.filledIconButtonColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                        contentColor = MaterialTheme.colorScheme.onErrorContainer,
                    ),
                    modifier = Modifier.size(40.dp),
                ) {
                    Icon(Icons.Outlined.Stop, contentDescription = "Stop")
                }
            } else {
                FilledIconButton(
                    onClick = onRun,
                    modifier = Modifier.size(40.dp),
                ) {
                    Icon(Icons.Outlined.PlayArrow, contentDescription = "Run")
                }
            }
            IconButton(onClick = { menuExpanded = true }) {
                Icon(Icons.Outlined.Edit, contentDescription = "Profile menu")
            }
            androidx.compose.material3.DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { menuExpanded = false },
            ) {
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("Edit") },
                    onClick = { menuExpanded = false; onEdit() },
                    leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
                )
                androidx.compose.material3.DropdownMenuItem(
                    text = { Text("Delete") },
                    onClick = { menuExpanded = false; onDelete() },
                    leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null) },
                )
            }
        }
    }
}

@Composable
private fun ActiveTaskRow(task: MobileRunTaskSnapshot, onStop: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier
                        .size(8.dp)
                        .background(Color(0xFF2E7D32), CircleShape),
                )
                Text(
                    task.profileName,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onStop) {
                    Icon(Icons.Outlined.Stop, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.size(4.dp))
                    Text("Stop")
                }
            }
            if (task.commandPreview.isNotBlank()) {
                Text(
                    task.commandPreview,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                )
            }
            task.terminalOutputTail?.takeIf { it.isNotBlank() }?.let { tail ->
                Surface(
                    color = MaterialTheme.colorScheme.surface,
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        tail,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 6,
                        modifier = Modifier.padding(10.dp),
                    )
                }
            }
            AssistChip(
                onClick = {},
                enabled = false,
                label = { Text(task.statusLabel) },
                colors = AssistChipDefaults.assistChipColors(),
            )
        }
    }
}

private fun RunProfile.subtitle(): String {
    return when (type) {
        RunProfileType.BASH -> bash.command.lineSequence().firstOrNull()?.takeIf { it.isNotBlank() }
            ?: "bash"
        RunProfileType.XCODE -> "xcode • ${xcode?.scheme?.ifBlank { "scheme?" } ?: "scheme?"}"
        RunProfileType.MAKE -> "make • ${make?.target?.ifBlank { "default" } ?: "default"}"
    }
}

private fun RunProfileType.icon(): ImageVector = when (this) {
    RunProfileType.BASH -> Icons.Outlined.Code
    RunProfileType.XCODE -> Icons.Outlined.Build
    RunProfileType.MAKE -> Icons.Outlined.Construction
}

private fun RunProfileType.tint(): Color = when (this) {
    RunProfileType.BASH -> Color(0xFF1976D2)
    RunProfileType.XCODE -> Color(0xFF6A1B9A)
    RunProfileType.MAKE -> Color(0xFFEF6C00)
}

/** Helper used by the host to seed a new bash profile when "+" is tapped. */
fun newBashRunProfile(projectId: UUID): RunProfile = RunProfile(
    projectId = projectId,
    name = "New profile",
    type = RunProfileType.BASH,
)
