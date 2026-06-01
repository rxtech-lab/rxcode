package app.rxlab.rxcode.ui.jsonschemaform

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import app.rxlab.rxcode.proto.RxJson
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/**
 * Holds the live form data + validation state for a [JsonSchemaForm]. Mirrors
 * iOS `FormData` + `JSONSchemaFormController`: call [submit] on save to get the
 * validated object, or null when validation fails (which flips on the inline
 * error display).
 */
class JsonSchemaFormState internal constructor(
    initial: JsonObject,
    private val schema: JsonObject,
) {
    var data by mutableStateOf(initial)
        private set

    var showErrors by mutableStateOf(false)
        internal set

    val errors: List<String> get() = validate(schema, data)

    fun setValue(path: List<String>, value: JsonElement?) {
        data = setIn(data, path, value)
    }

    fun getValue(path: List<String>): JsonElement? = getIn(data, path)

    /** Returns the validated object, or null (and shows errors) when invalid. */
    fun submit(): JsonObject? {
        return if (errors.isEmpty()) {
            data
        } else {
            showErrors = true
            null
        }
    }

    companion object {
        internal fun saver(schema: JsonObject): Saver<JsonSchemaFormState, String> = Saver(
            save = { RxJson.encodeToString(JsonObject.serializer(), it.data) },
            restore = { stored ->
                val obj = runCatching {
                    RxJson.decodeFromString(JsonObject.serializer(), stored)
                }.getOrDefault(JsonObject(emptyMap()))
                JsonSchemaFormState(obj, schema)
            },
        )
    }
}

/**
 * Builds (and remembers across config changes) a form state seeded from
 * [schema] defaults merged over [existing] saved values.
 */
@Composable
fun rememberJsonSchemaFormState(schema: JsonObject, existing: JsonElement?): JsonSchemaFormState {
    return rememberSaveable(saver = JsonSchemaFormState.saver(schema)) {
        JsonSchemaFormState(applyDefaults(schema, existing), schema)
    }
}

/**
 * Renders [schema] (a JSON Schema object) into Material 3 controls bound to
 * [state]. [uiSchema] is the optional RJSF-style UI schema (`ui:widget`,
 * `ui:order`, …).
 */
@Composable
fun JsonSchemaForm(
    schema: JsonObject,
    uiSchema: JsonObject?,
    state: JsonSchemaFormState,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SchemaObjectFields(
            schema = schema,
            uiSchema = uiSchema,
            path = emptyList(),
            required = schema.requiredKeys(),
            state = state,
        )
    }
}

@Composable
private fun SchemaObjectFields(
    schema: JsonObject,
    uiSchema: JsonObject?,
    path: List<String>,
    required: Set<String>,
    state: JsonSchemaFormState,
) {
    for (key in orderedKeys(schema, uiSchema)) {
        val prop = schema.properties()[key] ?: continue
        SchemaField(
            key = key,
            prop = prop,
            uiSchema = childUiSchema(uiSchema, key),
            widget = uiWidget(uiSchema, key),
            path = path + key,
            isRequired = key in required,
            state = state,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SchemaField(
    key: String,
    prop: JsonObject,
    uiSchema: JsonObject?,
    widget: String?,
    path: List<String>,
    isRequired: Boolean,
    state: JsonSchemaFormState,
) {
    val label = prop.titleOrKey(key) + if (isRequired) " *" else ""
    val description = prop.description()
    val current = state.getValue(path)
    val enumValues = prop.enumValues()
    val type = prop.schemaType()

    when {
        // Nested object → labeled section, recurse.
        type == "object" -> {
            HorizontalDivider()
            Text(
                prop.titleOrKey(key),
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(top = 4.dp),
            )
            description?.let { FieldHelp(it) }
            Column(
                Modifier.padding(start = 8.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                SchemaObjectFields(prop, uiSchema, path, prop.requiredKeys(), state)
            }
        }

        // Boolean → switch row.
        type == "boolean" -> {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(label, style = MaterialTheme.typography.bodyLarge)
                    description?.let { FieldHelp(it) }
                }
                Switch(
                    checked = (current as? JsonPrimitive)?.booleanOrNull ?: false,
                    onCheckedChange = { state.setValue(path, JsonPrimitive(it)) },
                )
            }
        }

        // Enum → dropdown.
        enumValues != null -> {
            var expanded by remember { mutableStateOf(false) }
            val selected = (current as? JsonPrimitive)?.contentOrNull ?: ""
            ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
                OutlinedTextField(
                    value = selected,
                    onValueChange = {},
                    readOnly = true,
                    label = { Text(label) },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                    supportingText = description?.let { { Text(it) } },
                    modifier = Modifier
                        .fillMaxWidth()
                        .menuAnchor(),
                )
                ExposedDropdownMenu(
                    expanded = expanded,
                    onDismissRequest = { expanded = false },
                ) {
                    enumValues.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(option) },
                            onClick = {
                                state.setValue(path, JsonPrimitive(option))
                                expanded = false
                            },
                        )
                    }
                }
            }
        }

        // Number / integer → numeric text field.
        type == "integer" || type == "number" -> {
            val text = (current as? JsonPrimitive)?.contentOrNull ?: ""
            OutlinedTextField(
                value = text,
                onValueChange = { raw ->
                    if (raw.isBlank()) {
                        state.setValue(path, null)
                    } else {
                        val num = if (type == "integer") raw.toLongOrNull() else raw.toDoubleOrNull()
                        // Store as a numeric primitive when parseable, else keep raw
                        // text so the user can keep typing; validation flags it.
                        state.setValue(path, num?.let { JsonPrimitive(it) } ?: JsonPrimitive(raw))
                    }
                },
                label = { Text(label) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    keyboardType = if (type == "integer") KeyboardType.Number else KeyboardType.Decimal,
                ),
                supportingText = description?.let { { Text(it) } },
                isError = state.showErrors && isRequired && text.isBlank(),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        // Fallback → string text field (single or multiline / password).
        else -> {
            val text = when (current) {
                is JsonPrimitive -> current.contentOrNull ?: ""
                null, is JsonNull -> ""
                else -> current.toString()
            }
            OutlinedTextField(
                value = text,
                onValueChange = { raw -> state.setValue(path, if (raw.isEmpty()) null else JsonPrimitive(raw)) },
                label = { Text(label) },
                singleLine = widget != "textarea",
                minLines = if (widget == "textarea") 4 else 1,
                visualTransformation = if (widget == "password") {
                    PasswordVisualTransformation()
                } else {
                    androidx.compose.ui.text.input.VisualTransformation.None
                },
                supportingText = description?.let { { Text(it) } },
                isError = state.showErrors && isRequired && text.isBlank(),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun FieldHelp(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}
