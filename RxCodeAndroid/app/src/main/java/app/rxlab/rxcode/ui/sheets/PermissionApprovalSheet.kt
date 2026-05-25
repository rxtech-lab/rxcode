package app.rxlab.rxcode.ui.sheets

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.PermissionRequestPayload
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/**
 * Bottom-sheet permission approval prompt. Replaces the lightweight
 * `AlertDialog` previously used inside the chat screen so we can show the
 * tool name prominently, render the payload JSON with monospace formatting,
 * and give the user two distinct buttons (Allow / Deny). Mirrors
 * `PermissionApprovalSheet` on iOS.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PermissionApprovalSheet(
    request: PermissionRequestPayload,
    onAllow: () -> Unit,
    onDeny: () -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = rememberHaptics()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val prettyPayload = remember(request.toolInputJSON) {
        prettyPrintJson(request.toolInputJSON)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.primaryContainer,
                    contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.size(44.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Outlined.Build, contentDescription = null)
                    }
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        "Allow tool?",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        request.toolName,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            Surface(
                shape = MaterialTheme.shapes.medium,
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 280.dp),
            ) {
                Box(Modifier.verticalScroll(rememberScrollState()).padding(12.dp)) {
                    Text(
                        prettyPayload,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = {
                        haptics.play(HapticEvent.HeavyImpact)
                        onDeny()
                    },
                    modifier = Modifier.weight(1f),
                ) { Text("Deny") }
                Button(
                    onClick = {
                        haptics.play(HapticEvent.LightTap)
                        onAllow()
                    },
                    modifier = Modifier.weight(1f),
                ) { Text("Allow") }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

/**
 * Pretty-print the desktop's tool-input JSON for the sheet body. Falls back
 * to the raw string if parsing fails so we never block on malformed data.
 */
private val prettyJson = Json { prettyPrint = true }

private fun prettyPrintJson(raw: String): String {
    return runCatching {
        val element = Json.parseToJsonElement(raw)
        prettyJson.encodeToString(JsonObject.serializer(), element.asJsonObject())
    }.getOrElse { raw }
}

private fun kotlinx.serialization.json.JsonElement.asJsonObject(): JsonObject =
    this as? JsonObject ?: JsonObject(mapOf("value" to this))
