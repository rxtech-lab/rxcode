package app.rxlab.rxcode.ui.sheets

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.TextSnippet
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Canvas
import app.rxlab.rxcode.proto.MobileThreadSummary
import app.rxlab.rxcode.proto.TodoItem
import app.rxlab.rxcode.ui.util.RxMarkdownText

/**
 * Bottom sheet listing the thread's todos and its desktop-generated summary,
 * mirroring the iOS `ThreadTodoSheet`. Opened from the chat navigation-title
 * progress badge.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThreadTodoSheet(
    threadTitle: String,
    todos: List<TodoItem>,
    summary: MobileThreadSummary?,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val doneCount = todos.count { it.status == TodoItem.Status.COMPLETED }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Text(
                threadTitle,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )

            if (todos.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeader(
                        icon = Icons.Outlined.Checklist,
                        label = "TODOS",
                        trailing = "$doneCount/${todos.size}",
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        todos.forEach { todo -> TodoRow(todo) }
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionHeader(icon = Icons.AutoMirrored.Outlined.TextSnippet, label = "SUMMARY")
                val summaryText = summary?.summary.orEmpty()
                if (summaryText.isNotEmpty()) {
                    RxMarkdownText(
                        markdown = summaryText,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                } else {
                    Text(
                        "No summary yet. A summary is generated once the thread finishes a turn on your Mac.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.outline,
                        fontFamily = FontFamily.Default,
                    )
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun SectionHeader(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    trailing: String? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(
            icon,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (trailing != null) {
            Spacer(Modifier.weight(1f))
            Text(
                trailing,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.outline,
            )
        }
    }
}

@Composable
private fun TodoRow(todo: TodoItem) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(Modifier.size(22.dp), contentAlignment = Alignment.Center) {
            when (todo.status) {
                TodoItem.Status.PENDING -> Icon(
                    Icons.Outlined.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(18.dp),
                )
                TodoItem.Status.IN_PROGRESS -> Icon(
                    Icons.AutoMirrored.Outlined.ArrowForward,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
                TodoItem.Status.COMPLETED -> Icon(
                    Icons.Outlined.CheckCircle,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        val label = if (todo.status == TodoItem.Status.IN_PROGRESS && todo.activeForm.isNotEmpty()) {
            todo.activeForm
        } else {
            todo.content
        }
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = when (todo.status) {
                TodoItem.Status.IN_PROGRESS -> MaterialTheme.colorScheme.onSurface
                else -> MaterialTheme.colorScheme.onSurfaceVariant
            },
            textDecoration = if (todo.status == TodoItem.Status.COMPLETED) TextDecoration.LineThrough else null,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/**
 * Compact ring + counter shown beside the chat navigation title. Mirrors the
 * iOS `MobileTodoProgressIndicator`.
 */
@Composable
fun TodoProgressBadge(
    done: Int,
    total: Int,
    inProgress: Boolean,
    modifier: Modifier = Modifier,
) {
    val isComplete = total > 0 && done == total
    val target = if (total > 0) (done.toFloat() / total.toFloat()).coerceIn(0f, 1f) else 0f
    val fraction by animateFloatAsState(targetValue = target, label = "todo-progress")
    val accent = when {
        isComplete -> Color(0xFF2E7D32)
        inProgress -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.outline
    }
    Row(
        modifier = modifier
            .background(
                color = MaterialTheme.colorScheme.surfaceContainerHighest,
                shape = RoundedCornerShape(50),
            )
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(Modifier.size(15.dp), contentAlignment = Alignment.Center) {
            val ringColor = accent
            val trackColor = accent.copy(alpha = 0.22f)
            Canvas(modifier = Modifier.size(15.dp).rotate(-90f)) {
                val stroke = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round)
                drawCircle(color = trackColor, style = stroke)
                drawArc(
                    color = ringColor,
                    startAngle = 0f,
                    sweepAngle = 360f * fraction,
                    useCenter = false,
                    style = stroke,
                    topLeft = Offset.Zero,
                    size = Size(size.width, size.height),
                )
            }
        }
        Text(
            "$done/$total",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
