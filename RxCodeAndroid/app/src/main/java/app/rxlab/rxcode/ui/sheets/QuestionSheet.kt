package app.rxlab.rxcode.ui.sheets

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.PendingQuestionPayload
import app.rxlab.rxcode.proto.QuestionAnswerEntry
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Agent question sheet. The desktop ships a JSON-encoded
 * `AskUserQuestion` tool payload via `question_queue`, and the user picks
 * answers and submits them back as `QuestionAnswerEntry` rows.
 *
 * Supports radio (single-select), checkbox (multi-select), and a free-text
 * "Other" field for each question. Mirrors `MobileQuestionSheet` on iOS.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuestionSheet(
    pending: PendingQuestionPayload,
    onDismiss: () -> Unit,
    onSubmit: (answers: List<QuestionAnswerEntry>) -> Unit,
) {
    val haptics = rememberHaptics()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val parsed = remember(pending.toolInputJSON) {
        runCatching { Json.decodeFromString(QuestionToolInput.serializer(), pending.toolInputJSON) }
            .getOrNull()
            ?: QuestionToolInput(questions = emptyList())
    }
    val selections = remember { mutableStateMapOf<Int, MutableList<String>>() }
    val freeText = remember { mutableStateMapOf<Int, String>() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                "Claude has a question",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
            )

            parsed.questions.forEachIndexed { index, q ->
                QuestionBlock(
                    question = q,
                    selected = selections[index].orEmpty(),
                    onToggle = { value ->
                        val current = selections.getOrPut(index) { mutableListOf() }
                        if (q.multiSelect) {
                            if (value in current) current.remove(value) else current.add(value)
                        } else {
                            current.clear(); current.add(value)
                        }
                        selections[index] = current
                        haptics.play(HapticEvent.Selection)
                    },
                    free = freeText[index].orEmpty(),
                    onFreeTextChange = { freeText[index] = it },
                )
            }

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = {
                        haptics.play(HapticEvent.LightTap)
                        val answers = parsed.questions.mapIndexed { index, q ->
                            val picks = selections[index].orEmpty().toMutableList()
                            val custom = freeText[index]?.trim().orEmpty()
                            if (custom.isNotEmpty()) picks.add(custom)
                            QuestionAnswerEntry(
                                questionIndex = index,
                                values = picks,
                                multiSelect = q.multiSelect,
                            )
                        }
                        onSubmit(answers)
                    },
                    enabled = parsed.questions.indices.all { idx ->
                        selections[idx]?.isNotEmpty() == true ||
                            (freeText[idx]?.trim()?.isNotEmpty() == true)
                    },
                ) { Text("Submit") }
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun QuestionBlock(
    question: QuestionToolInput.Question,
    selected: List<String>,
    onToggle: (String) -> Unit,
    free: String,
    onFreeTextChange: (String) -> Unit,
) {
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(question.question, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            question.options.forEach { option ->
                val checked = option.label in selected
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 2.dp),
                ) {
                    if (question.multiSelect) {
                        Checkbox(checked = checked, onCheckedChange = { onToggle(option.label) })
                    } else {
                        RadioButton(selected = checked, onClick = { onToggle(option.label) })
                    }
                    Column(Modifier.padding(start = 6.dp)) {
                        Text(option.label, style = MaterialTheme.typography.bodyMedium)
                        if (!option.description.isNullOrBlank()) {
                            Text(
                                option.description,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
            OutlinedTextField(
                value = free,
                onValueChange = onFreeTextChange,
                label = { Text("Other (optional)") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
        }
    }
}

@Serializable
private data class QuestionToolInput(val questions: List<Question> = emptyList()) {
    @Serializable
    data class Question(
        val question: String = "",
        val header: String = "",
        val multiSelect: Boolean = false,
        val options: List<Option> = emptyList(),
    )

    @Serializable
    data class Option(val label: String, val description: String? = null)
}
