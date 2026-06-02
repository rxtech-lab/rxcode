package app.rxlab.rxcode.ui.jsonschemaform

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Lightweight JSON-Schema helpers backing [JsonSchemaForm]. There is no
 * JSONSchemaForm equivalent on Android, so this package renders a subset of
 * JSON Schema Draft-07 (object/string/number/integer/boolean/enum/array, plus
 * `title`/`description`/`default`/`required`) into Material 3 controls — the
 * same shape the iOS app feeds the `JSONSchemaForm` Swift library.
 */

/** Returns the schema's declared type, tolerating `["string","null"]` unions. */
fun JsonObject.schemaType(): String? = when (val t = this["type"]) {
    is JsonPrimitive -> t.contentOrNull
    is JsonArray -> t.firstOrNull { (it as? JsonPrimitive)?.contentOrNull != "null" }
        ?.let { (it as? JsonPrimitive)?.contentOrNull }
    else -> null
}

fun JsonObject.titleOrKey(key: String): String =
    (this["title"] as? JsonPrimitive)?.contentOrNull ?: humanize(key)

fun JsonObject.description(): String? = (this["description"] as? JsonPrimitive)?.contentOrNull

fun JsonObject.enumValues(): List<String>? =
    (this["enum"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }

fun JsonObject.requiredKeys(): Set<String> =
    (this["required"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }?.toSet()
        ?: emptySet()

fun JsonObject.properties(): Map<String, JsonObject> =
    (this["properties"] as? JsonObject)?.mapNotNull { (k, v) ->
        (v as? JsonObject)?.let { k to it }
    }?.toMap() ?: emptyMap()

/** Property render order honoring an optional uiSchema `ui:order`. */
fun orderedKeys(schema: JsonObject, uiSchema: JsonObject?): List<String> {
    val keys = schema.properties().keys.toList()
    val order = (uiSchema?.get("ui:order") as? JsonArray)
        ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        ?: return keys
    val wildcard = order.indexOf("*")
    val explicit = order.filter { it != "*" && it in keys }
    val rest = keys.filter { it !in explicit }
    return if (wildcard >= 0) {
        val before = order.subList(0, wildcard).filter { it in keys }
        val after = order.subList(wildcard + 1, order.size).filter { it in keys }
        before + rest.filter { it !in after } + after
    } else {
        explicit + rest
    }
}

/** The `ui:widget` hint for a field (`textarea`, `password`, etc.), if any. */
fun uiWidget(uiSchema: JsonObject?, key: String): String? =
    ((uiSchema?.get(key) as? JsonObject)?.get("ui:widget") as? JsonPrimitive)?.contentOrNull

fun childUiSchema(uiSchema: JsonObject?, key: String): JsonObject? =
    uiSchema?.get(key) as? JsonObject

/**
 * Merge saved [existing] values over the schema defaults so the form opens
 * pre-filled. Mirrors `FormData.applyingDefaults(schema:)` on iOS.
 */
fun applyDefaults(schema: JsonObject, existing: JsonElement?): JsonObject {
    val out = linkedMapOf<String, JsonElement>()
    val existingObj = existing as? JsonObject
    for ((key, prop) in schema.properties()) {
        val saved = existingObj?.get(key)
        when (prop.schemaType()) {
            "object" -> out[key] = applyDefaults(prop, saved)
            else -> {
                val value = saved ?: prop["default"]
                if (value != null && value !is JsonNull) out[key] = value
            }
        }
    }
    // Preserve any saved keys the schema doesn't describe.
    existingObj?.forEach { (k, v) -> if (k !in out) out[k] = v }
    return JsonObject(out)
}

/** Immutable set of a value at a key path, creating intermediate objects. */
fun setIn(obj: JsonObject, path: List<String>, value: JsonElement?): JsonObject {
    if (path.isEmpty()) return obj
    val key = path.first()
    val map = obj.toMutableMap()
    if (path.size == 1) {
        if (value == null) map.remove(key) else map[key] = value
    } else {
        val child = map[key] as? JsonObject ?: JsonObject(emptyMap())
        map[key] = setIn(child, path.drop(1), value)
    }
    return JsonObject(map)
}

fun getIn(obj: JsonObject, path: List<String>): JsonElement? {
    var cursor: JsonElement = obj
    for (key in path) {
        cursor = (cursor as? JsonObject)?.get(key) ?: return null
    }
    return cursor
}

/** Validate required + numeric fields. Returns human-readable error messages. */
fun validate(schema: JsonObject, data: JsonObject, prefix: String = ""): List<String> {
    val errors = mutableListOf<String>()
    val required = schema.requiredKeys()
    for ((key, prop) in schema.properties()) {
        val label = prop.titleOrKey(key)
        val value = data[key]
        val present = value != null && value !is JsonNull &&
            !(value is JsonPrimitive && value.isString && value.content.isBlank())
        if (key in required && !present) {
            errors += "${if (prefix.isEmpty()) "" else "$prefix · "}$label is required."
            continue
        }
        if (!present) continue
        when (prop.schemaType()) {
            "integer", "number" -> {
                val ok = (value as? JsonPrimitive)?.let {
                    it.doubleOrNull != null || it.contentOrNull?.toDoubleOrNull() != null
                } ?: false
                if (!ok) errors += "$label must be a number."
            }
            "object" -> {
                if (value is JsonObject) errors += validate(prop, value, label)
            }
            else -> Unit
        }
    }
    return errors
}

private fun humanize(key: String): String =
    key.replace('_', ' ')
        .replace(Regex("([a-z])([A-Z])"), "$1 $2")
        .replaceFirstChar { it.uppercaseChar() }
