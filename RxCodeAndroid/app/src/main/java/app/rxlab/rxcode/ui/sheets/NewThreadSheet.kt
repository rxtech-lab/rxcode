package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.EditNote
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.PermissionMode
import app.rxlab.rxcode.proto.ProjectBranchInfo
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics
import java.util.UUID

/**
 * New-thread bottom sheet. Mirrors iOS `NewThreadSheet`: a hero header that
 * names the project, a rounded composer card with an embedded gradient send
 * button, and a chip strip for the per-thread agent config (branch, permission
 * mode, plan mode). The branch chip only updates the local picker state — the
 * actual switch happens on the desktop the next time we wire up
 * `branch_op_request`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewThreadSheet(
    viewModel: MobileAppState,
    projectId: UUID,
    projectName: String?,
    branchInfo: ProjectBranchInfo?,
    preferredBranch: String? = null,
    onDismiss: () -> Unit,
    onSessionCreated: (sessionId: String) -> Unit,
) {
    val haptics = rememberHaptics()
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = true,
        confirmValueChange = { it != SheetValue.Hidden },
    )

    var planMode by remember { mutableStateOf(false) }
    var permissionMode by remember { mutableStateOf(PermissionMode.DEFAULT) }
    var prompt by remember { mutableStateOf("") }
    val resolvedBranch = remember(branchInfo, preferredBranch) {
        preferredBranch ?: branchInfo?.currentBranch
    }
    var selectedBranch by remember(resolvedBranch) { mutableStateOf(resolvedBranch) }

    val canSend = prompt.trim().isNotEmpty()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surfaceContainerLow,
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            TopBar(onCancel = onDismiss)

            HeroHeader(projectName = projectName)

            ComposerCard(
                text = prompt,
                onTextChange = { prompt = it },
                canSend = canSend,
                onSend = {
                    if (canSend) {
                        haptics.play(HapticEvent.LightTap)
                        val draftId = viewModel.startNewSession(
                            projectId = projectId,
                            initialText = prompt.trim(),
                            planMode = planMode,
                            permissionMode = permissionMode.takeIf { it != PermissionMode.DEFAULT },
                        )
                        onSessionCreated(draftId)
                    }
                },
            )

            SettingsStrip(
                branchInfo = branchInfo,
                selectedBranch = selectedBranch,
                onSelectBranch = {
                    haptics.play(HapticEvent.Selection)
                    selectedBranch = it
                },
                permissionMode = permissionMode,
                onSelectPermission = {
                    haptics.play(HapticEvent.Selection)
                    permissionMode = it
                },
                planMode = planMode,
                onTogglePlan = {
                    haptics.play(HapticEvent.Selection)
                    planMode = !planMode
                },
            )

            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun TopBar(onCancel: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        TextButton(
            onClick = onCancel,
            modifier = Modifier.align(Alignment.CenterStart),
        ) { Text("Cancel") }
        Text(
            text = "New Thread",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.align(Alignment.Center),
        )
    }
}

@Composable
private fun HeroHeader(projectName: String?) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(54.dp)
                .clip(CircleShape)
                .background(accentGradient(alpha = 0.18f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Outlined.AutoAwesome,
                contentDescription = null,
                tint = Color(0xFFE8704C),
                modifier = Modifier.size(28.dp),
            )
        }
        Text(
            text = "What should we build in ${projectName ?: "this project"}?",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center,
        )
        Text(
            text = "Describe a task, paste a snippet, or ask a question.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun ComposerCard(
    text: String,
    onTextChange: (String) -> Unit,
    canSend: Boolean,
    onSend: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        tonalElevation = 0.dp,
        shadowElevation = 2.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box {
                if (text.isEmpty()) {
                    Text(
                        text = "Describe what to build…",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    )
                }
                BasicTextField(
                    value = text,
                    onValueChange = onTextChange,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(
                        color = MaterialTheme.colorScheme.onSurface,
                    ),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 96.dp, max = 240.dp),
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                SendButton(enabled = canSend, onClick = onSend)
            }
        }
    }
}

@Composable
private fun SendButton(enabled: Boolean, onClick: () -> Unit) {
    val background = if (enabled) accentGradient() else SolidColor(
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f),
    )
    val contentColor = if (enabled) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
    Box(
        modifier = Modifier
            .size(38.dp)
            .clip(CircleShape)
            .background(background)
            .clickable(enabled = enabled, onClick = onClick)
            .graphicsLayer { alpha = if (enabled) 1f else 0.85f },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.AutoMirrored.Outlined.ArrowForward,
            contentDescription = "Send",
            tint = contentColor,
            modifier = Modifier
                .size(18.dp)
                .graphicsLayer { rotationZ = -90f },
        )
    }
}

@Composable
private fun SettingsStrip(
    branchInfo: ProjectBranchInfo?,
    selectedBranch: String?,
    onSelectBranch: (String) -> Unit,
    permissionMode: PermissionMode,
    onSelectPermission: (PermissionMode) -> Unit,
    planMode: Boolean,
    onTogglePlan: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            text = "SETTINGS",
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        BranchChip(
            branchInfo = branchInfo,
            selected = selectedBranch,
            onSelect = onSelectBranch,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PermissionChip(
                mode = permissionMode,
                onSelect = onSelectPermission,
                modifier = Modifier.weight(1f),
            )
            PlanToggleChip(
                active = planMode,
                onClick = onTogglePlan,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun BranchChip(
    branchInfo: ProjectBranchInfo?,
    selected: String?,
    onSelect: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val branches = remember(branchInfo) {
        val current = branchInfo?.currentBranch
        val all = branchInfo?.availableBranches.orEmpty()
        when {
            all.isNotEmpty() && current != null -> listOf(current) + all.filter { it != current }
            all.isNotEmpty() -> all
            current != null -> listOf(current)
            else -> emptyList()
        }
    }
    val label = selected ?: branchInfo?.currentBranch ?: "No branch"

    Box(Modifier.fillMaxWidth()) {
        ChipSurface(
            icon = Icons.Outlined.AccountTree,
            title = label,
            showsChevron = branches.isNotEmpty(),
            enabled = branches.isNotEmpty(),
            onClick = { if (branches.isNotEmpty()) open = true },
            modifier = Modifier.fillMaxWidth(),
        )
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
        ) {
            branches.forEach { branch ->
                val isSelected = branch == (selected ?: branchInfo?.currentBranch)
                DropdownMenuItem(
                    text = { Text(branch) },
                    leadingIcon = {
                        Icon(
                            if (isSelected) Icons.Outlined.Check else Icons.Outlined.AccountTree,
                            contentDescription = null,
                        )
                    },
                    onClick = {
                        open = false
                        onSelect(branch)
                    },
                )
            }
        }
    }
}

@Composable
private fun PermissionChip(
    mode: PermissionMode,
    onSelect: (PermissionMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    var open by remember { mutableStateOf(false) }
    val pickable = listOf(
        PermissionMode.DEFAULT,
        PermissionMode.ACCEPT_EDITS,
        PermissionMode.BYPASS_PERMISSIONS,
    )

    Box(modifier) {
        ChipSurface(
            icon = mode.icon(),
            title = mode.displayName(),
            showsChevron = true,
            onClick = { open = true },
            modifier = Modifier.fillMaxWidth(),
        )
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
        ) {
            pickable.forEach { item ->
                val isSelected = item == mode
                DropdownMenuItem(
                    text = { Text(item.displayName()) },
                    leadingIcon = {
                        Icon(item.icon(), contentDescription = null)
                    },
                    trailingIcon = {
                        if (isSelected) Icon(Icons.Outlined.Check, contentDescription = null)
                    },
                    onClick = {
                        open = false
                        onSelect(item)
                    },
                )
            }
        }
    }
}

@Composable
private fun PlanToggleChip(
    active: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ChipSurface(
        icon = Icons.Outlined.Lightbulb,
        title = "Plan mode",
        showsChevron = false,
        active = active,
        onClick = onClick,
        modifier = modifier.fillMaxWidth(),
    )
}

@Composable
private fun ChipSurface(
    icon: ImageVector,
    title: String,
    showsChevron: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    active: Boolean = false,
) {
    val shape = RoundedCornerShape(14.dp)
    val container = when {
        active -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.surfaceContainerHigh
    }
    val content = when {
        active -> MaterialTheme.colorScheme.onPrimary
        enabled -> MaterialTheme.colorScheme.onSurface
        else -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f)
    }
    Surface(
        shape = shape,
        color = container,
        contentColor = content,
        modifier = modifier
            .clip(shape)
            .clickable(enabled = enabled, onClick = onClick),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = LocalContentColor.current,
                maxLines = 1,
                modifier = Modifier.weight(1f, fill = false),
            )
            if (showsChevron) {
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Outlined.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = LocalContentColor.current.copy(alpha = 0.7f),
                )
            }
        }
    }
}

private fun accentGradient(alpha: Float = 1f): Brush = Brush.linearGradient(
    colors = listOf(
        Color(red = 0.95f, green = 0.6f, blue = 0.4f, alpha = alpha),
        Color(red = 0.85f, green = 0.5f, blue = 0.55f, alpha = alpha),
        Color(red = 0.65f, green = 0.5f, blue = 0.7f, alpha = alpha),
    ),
)

private fun PermissionMode.displayName(): String = when (this) {
    PermissionMode.DEFAULT -> "Default"
    PermissionMode.ACCEPT_EDITS -> "Accept edits"
    PermissionMode.BYPASS_PERMISSIONS -> "Bypass"
    PermissionMode.PLAN -> "Plan"
}

private fun PermissionMode.icon(): ImageVector = when (this) {
    PermissionMode.DEFAULT -> Icons.Outlined.Shield
    PermissionMode.ACCEPT_EDITS -> Icons.Outlined.EditNote
    PermissionMode.BYPASS_PERMISSIONS -> Icons.Outlined.LockOpen
    PermissionMode.PLAN -> Icons.Outlined.Lightbulb
}
