import Foundation
import RxCodeCore

/// Matches saved Agent Chat results by call ID, including results in later messages.
public enum SavedSessionToolCalls {
    public static func groups(in messages: [JSONValue]) -> [[ToolCall]] {
        let calls = messages.flatMap { $0["toolCalls"]?.arrayValue ?? [] }
        let callIDs = Set(calls.compactMap { $0["id"]?.stringValue })
        var results: [String: JSONValue] = [:]
        for message in messages {
            for result in message["toolResults"]?.arrayValue ?? [] {
                if let id = result["id"]?.stringValue { results[id] = result }
            }
        }
        return messages.enumerated().map { messageIndex, message in
            var group = (message["toolCalls"]?.arrayValue ?? []).enumerated().map { index, call in
                let id = call["id"]?.stringValue ?? "saved-\(messageIndex)-\(index)"
                let arguments = call["arguments"] ?? .object([:])
                let input: [String: JSONValue]
                if case .object(let object) = arguments { input = object }
                else { input = ["arguments": arguments] }
                let result = results[id]
                return ToolCall(id: id, name: call["name"]?.stringValue ?? "Tool", input: input,
                                result: result.map { resultText($0["result"] ?? .null) },
                                isError: result.map(isError) ?? false)
            }
            // Keep orphan results inspectable, but do not repeat matched results.
            for (index, result) in (message["toolResults"]?.arrayValue ?? []).enumerated() {
                if let id = result["id"]?.stringValue, callIDs.contains(id) { continue }
                group.append(ToolCall(id: result["id"]?.stringValue ?? "result-\(messageIndex)-\(index)",
                                      name: result["name"]?.stringValue ?? "Tool",
                                      result: resultText(result["result"] ?? .null), isError: isError(result)))
            }
            return group
        }
    }

    private static func resultText(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    private static func isError(_ result: JSONValue) -> Bool {
        result["isError"]?.boolValue == true || result["result"]?["isError"]?.boolValue == true
            || result["result"]?["success"]?.boolValue == false
    }
}
