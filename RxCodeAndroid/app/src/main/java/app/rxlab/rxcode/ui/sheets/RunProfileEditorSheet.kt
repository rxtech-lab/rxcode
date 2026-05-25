package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Button
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.BashRunConfig
import app.rxlab.rxcode.proto.MakeRunConfig
import app.rxlab.rxcode.proto.RunProfile
import app.rxlab.rxcode.proto.RunProfileType
import app.rxlab.rxcode.proto.XcodeRunConfig
import java.time.Instant

/**
 * Editor sheet for a single [RunProfile]. Bash gets a full form (name,
 * command, working directory); xcode/make get the minimum fields needed to
 * round-trip the profile so iOS/desktop edits aren't clobbered. Heavy editing
 * for those types is intentionally left to the desktop, where file pickers
 * make it practical.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RunProfileEditorSheet(
    initial: RunProfile,
    onSave: (RunProfile) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var name by remember(initial.id) { mutableStateOf(initial.name) }
    var type by remember(initial.id) { mutableStateOf(initial.type) }
    var bashCommand by remember(initial.id) { mutableStateOf(initial.bash.command) }
    var bashCwd by remember(initial.id) { mutableStateOf(initial.bash.workingDirectory) }
    var xcodeScheme by remember(initial.id) { mutableStateOf(initial.xcode?.scheme.orEmpty()) }
    var xcodeContainer by remember(initial.id) { mutableStateOf(initial.xcode?.container.orEmpty()) }
    var makeTarget by remember(initial.id) { mutableStateOf(initial.make?.target.orEmpty()) }
    var makeArguments by remember(initial.id) { mutableStateOf(initial.make?.arguments.orEmpty()) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                if (initial.name.isBlank()) "New run profile" else "Edit run profile",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Name") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Type", style = MaterialTheme.typography.labelMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    RunProfileType.entries.forEach { option ->
                        FilterChip(
                            selected = type == option,
                            onClick = { type = option },
                            label = { Text(option.label()) },
                        )
                    }
                }
            }

            when (type) {
                RunProfileType.BASH -> {
                    OutlinedTextField(
                        value = bashCommand,
                        onValueChange = { bashCommand = it },
                        label = { Text("Command") },
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 120.dp),
                    )
                    OutlinedTextField(
                        value = bashCwd,
                        onValueChange = { bashCwd = it },
                        label = { Text("Working directory (project-relative)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                RunProfileType.XCODE -> {
                    OutlinedTextField(
                        value = xcodeContainer,
                        onValueChange = { xcodeContainer = it },
                        label = { Text("Project / Workspace") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = xcodeScheme,
                        onValueChange = { xcodeScheme = it },
                        label = { Text("Scheme") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    DesktopOnlyHint("Full Xcode destination/configuration editing lives on the desktop.")
                }
                RunProfileType.MAKE -> {
                    OutlinedTextField(
                        value = makeTarget,
                        onValueChange = { makeTarget = it },
                        label = { Text("Target") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = makeArguments,
                        onValueChange = { makeArguments = it },
                        label = { Text("Arguments") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    DesktopOnlyHint("Pick a custom Makefile path on the desktop.")
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onDismiss, modifier = Modifier.weight(1f)) { Text("Cancel") }
                Button(
                    enabled = name.isNotBlank(),
                    onClick = {
                        val updated = initial.copy(
                            name = name.trim(),
                            type = type,
                            bash = initial.bash.copy(
                                command = bashCommand,
                                workingDirectory = bashCwd,
                            ),
                            xcode = when (type) {
                                RunProfileType.XCODE -> (initial.xcode ?: XcodeRunConfig()).copy(
                                    container = xcodeContainer,
                                    scheme = xcodeScheme,
                                )
                                else -> initial.xcode
                            },
                            make = when (type) {
                                RunProfileType.MAKE -> (initial.make ?: MakeRunConfig()).copy(
                                    target = makeTarget,
                                    arguments = makeArguments,
                                )
                                else -> initial.make
                            },
                            updatedAt = Instant.now(),
                        )
                        onSave(updated)
                    },
                    modifier = Modifier.weight(1f),
                ) { Text("Save") }
            }
        }
    }
}

@Composable
private fun DesktopOnlyHint(message: String) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
    ) {
        Text(
            message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(12.dp),
        )
    }
}

private fun RunProfileType.label(): String = when (this) {
    RunProfileType.BASH -> "Bash"
    RunProfileType.XCODE -> "Xcode"
    RunProfileType.MAKE -> "Make"
}

@Suppress("unused")
private fun BashRunConfig.placeholder(): String =
    if (command.isBlank()) "echo hello" else command.lineSequence().first()
