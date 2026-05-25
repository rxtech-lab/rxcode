package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.ProjectBranchInfo
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics
import java.util.UUID

/**
 * New-thread bottom sheet — mirrors iOS `NewThreadSheet`. Shows the project's
 * current and available branches (read from the most-recent
 * `project_branches` snapshot), a plan-mode toggle, and an initial prompt
 * field. The "Start" button is enabled as soon as we have a branch resolved.
 *
 * Picking a different branch from the current one isn't wired to
 * `branch_op_request` yet — for now we surface the picker so the user can
 * verify which branch the desktop will run on. A future change can switch the
 * branch via `BranchOpRequestPayload.Operation.SWITCH_EXISTING` before the
 * thread is created.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewThreadSheet(
    projectId: UUID,
    branchInfo: ProjectBranchInfo?,
    preferredBranch: String? = null,
    onDismiss: () -> Unit,
    onSubmit: (planMode: Boolean, initialText: String, branch: String?) -> Unit,
) {
    val haptics = rememberHaptics()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var planMode by remember { mutableStateOf(false) }
    var prompt by remember { mutableStateOf("") }
    val resolvedBranch = remember(branchInfo, preferredBranch) {
        preferredBranch ?: branchInfo?.currentBranch
    }
    var selectedBranch by remember(resolvedBranch) { mutableStateOf(resolvedBranch) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("New thread", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)

            // Branch row
            BranchSelector(
                branchInfo = branchInfo,
                selected = selectedBranch,
                onSelect = {
                    haptics.play(HapticEvent.Selection)
                    selectedBranch = it
                },
            )

            HorizontalDivider()

            ListItem(
                headlineContent = { Text("Plan mode") },
                supportingContent = {
                    Text("Ask Claude to propose a plan before editing.")
                },
                leadingContent = {
                    Icon(Icons.Outlined.Lightbulb, contentDescription = null)
                },
                trailingContent = {
                    Switch(
                        checked = planMode,
                        onCheckedChange = {
                            haptics.play(HapticEvent.Selection)
                            planMode = it
                        },
                    )
                },
                modifier = Modifier.padding(horizontal = 0.dp),
            )

            OutlinedTextField(
                value = prompt,
                onValueChange = { prompt = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(140.dp),
                label = { Text("Initial message (optional)") },
                placeholder = { Text("What would you like to work on?") },
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                TextButton(
                    onClick = onDismiss,
                    modifier = Modifier.padding(vertical = 4.dp),
                ) { Text("Cancel") }
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = {
                        haptics.play(HapticEvent.LightTap)
                        onSubmit(planMode, prompt.trim(), selectedBranch)
                    },
                    enabled = true,
                    colors = ButtonDefaults.buttonColors(),
                ) { Text("Start") }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun BranchSelector(
    branchInfo: ProjectBranchInfo?,
    selected: String?,
    onSelect: (String) -> Unit,
) {
    val branches = remember(branchInfo) {
        val all = branchInfo?.availableBranches.orEmpty()
        val current = branchInfo?.currentBranch
        when {
            all.isNotEmpty() && current != null -> listOf(current) + all.filter { it != current }
            all.isNotEmpty() -> all
            current != null -> listOf(current)
            else -> emptyList()
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(
                Icons.Outlined.AccountTree,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp),
            )
            Text("Branch", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
        }
        if (branches.isEmpty()) {
            Text(
                "No branch info yet — the thread will run on whatever branch the desktop has checked out.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.outline,
            )
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                branches.forEach { branch ->
                    BranchRow(
                        branch = branch,
                        isSelected = branch == selected,
                        onClick = { onSelect(branch) },
                    )
                }
            }
        }
    }
}

@Composable
private fun BranchRow(
    branch: String,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = MaterialTheme.shapes.medium,
        color = if (isSelected) MaterialTheme.colorScheme.primaryContainer
        else MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                Icons.Outlined.AccountTree,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = if (isSelected) MaterialTheme.colorScheme.onPrimaryContainer
                else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                branch,
                style = MaterialTheme.typography.bodyMedium,
                color = if (isSelected) MaterialTheme.colorScheme.onPrimaryContainer
                else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            if (isSelected) {
                Icon(
                    Icons.Outlined.Check,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}
