import Foundation

// Codable DTOs mirroring github-pm's autopilot configuration JSON shapes
// (`/api/v1/automation/*`, `/api/v1/preferences`, `/api/v1/repo-setup/*`).
// Arbitrary JSON (schemas, ui schemas, values, merge settings, rulesets) is
// carried as `JSONValue` so RxCodeCore never has to import the form renderer.

public extension JSONValue {
    /// A compact JSON string of this value, suitable for feeding the
    /// `JSONSchemaForm` renderer (`JSONSchema(jsonString:)`,
    /// `FormData.fromJSONString(_:)`).
    var rawJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "null" }
        return string
    }

    /// A human-readable, pretty-printed JSON string for editors.
    var prettyJSONString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return rawJSONString }
        return string
    }

    /// A Foundation object tree (`[String: Any]`, `[Any]`, `NSNull`, scalars)
    /// suitable for the renderer's `uiSchema: [String: Any]?` parameter.
    var foundationObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues { $0.foundationObject }
        case .array(let value): return value.map { $0.foundationObject }
        case .null: return NSNull()
        }
    }

    /// Decodes a `JSONValue` from raw JSON bytes.
    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: jsonData)
    }
}

// MARK: - Schema envelope

/// Response of the schema endpoints: a JSON Schema plus an optional RJSF-style
/// ui schema (`/api/v1/automation/schema`, `/api/v1/repo-setup/schema`).
public struct SchemaEnvelope: Codable, Sendable {
    public let schema: JSONValue
    public let uiSchema: JSONValue?

    public init(schema: JSONValue, uiSchema: JSONValue? = nil) {
        self.schema = schema
        self.uiSchema = uiSchema
    }
}

// MARK: - Automation preferences (values)

/// Wrapper for `GET`/`PUT /api/v1/preferences` — the saved automation settings
/// values, opaque to the app (rendered/validated against the schema).
public struct PreferencesValues: Codable, Sendable {
    public let values: JSONValue

    public init(values: JSONValue) {
        self.values = values
    }
}
