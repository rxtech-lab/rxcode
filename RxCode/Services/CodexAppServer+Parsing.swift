import Foundation
import RxCodeCore
import os

extension CodexAppServer {
    func toolName(from item: [String: JSONValue]) -> String? {
        if let type = Self.firstString(in: item, keys: ["type", "kind"]) {
            let normalizedType = type.lowercased()
            if normalizedType.contains("command") { return "Bash" }
            if normalizedType.contains("file") || normalizedType.contains("patch") { return "Edit" }
            if normalizedType.contains("message") { return "message" }
            return type
        }
        guard let name = Self.firstString(in: item, keys: ["name", "toolName"]) else { return nil }
        return name.lowercased().contains("message") ? "message" : name
    }

    static func parseModels(from value: JSONValue) -> [AgentModel] {
        let root = value.objectValue
        let rawModels = root?["data"]?.arrayValue ?? root?["models"]?.arrayValue ?? root?["items"]?.arrayValue ?? value.arrayValue ?? []
        return rawModels.compactMap { entry in
            if let id = entry.stringValue {
                return AgentModel(provider: .codex, id: id, displayName: AppStateModelFormatter.codexDisplayName(id), description: "Codex model served by the Codex app-server.")
            }
            guard let object = entry.objectValue,
                  let id = firstString(in: object, keys: ["id", "slug", "model", "name"]) else { return nil }
            if object["hidden"]?.boolValue == true || object["visibility"]?.stringValue == "hidden" {
                return nil
            }
            let displayName = firstString(in: object, keys: ["displayName", "display_name", "name"]) ?? AppStateModelFormatter.codexDisplayName(id)
            let description = firstString(in: object, keys: ["description", "detail"]) ?? "Codex model served by the Codex app-server."
            return AgentModel(provider: .codex, id: id, displayName: displayName, description: description)
        }
    }

    static func idString(_ value: JSONValue?) -> String? {
        if let s = value?.stringValue { return s }
        if let n = value?.numberValue {
            if n.rounded() == n { return String(Int(n)) }
            return String(n)
        }
        return nil
    }

    static func threadId(from value: JSONValue) -> String? {
        if let object = value.objectValue {
            if let id = firstString(in: object, keys: ["threadId", "thread_id", "id"]) { return id }
            if let nested = object["thread"]?.objectValue {
                return firstString(in: nested, keys: ["threadId", "thread_id", "id"])
            }
        }
        return value.stringValue
    }

    static func firstString(in object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue { return value }
            if let number = object[key]?.numberValue { return String(number) }
        }
        return nil
    }

    static func parseCodexRateLimits(from value: JSONValue) -> RateLimitUsage? {
        guard let snapshot = codexRateLimitSnapshot(from: value) else { return nil }
        let windows = [
            parseCodexRateLimitWindow(snapshot["primary"]),
            parseCodexRateLimitWindow(snapshot["secondary"])
        ].compactMap { $0 }

        guard !windows.isEmpty else { return nil }
        let fiveHour = windows.first { $0.durationMinutes == 300 } ?? windows.first
        let twentyFourHour = windows.first { $0.durationMinutes == 1_440 }
            ?? windows.first { $0.durationMinutes != fiveHour?.durationMinutes }
            ?? windows.dropFirst().first

        return RateLimitUsage(
            fiveHourPercent: fiveHour?.percent ?? 0,
            sevenDayPercent: 0,
            twentyFourHourPercent: twentyFourHour?.percent,
            fiveHourResetsAt: fiveHour?.resetsAt,
            sevenDayResetsAt: nil,
            twentyFourHourResetsAt: twentyFourHour?.resetsAt
        )
    }

    static func codexRateLimitSnapshot(from value: JSONValue) -> [String: JSONValue]? {
        guard let object = value.objectValue else { return nil }

        if let byLimitId = object["rateLimitsByLimitId"]?.objectValue {
            if let codex = byLimitId["codex"]?.objectValue {
                return codex
            }
            for snapshot in byLimitId.values.compactMap(\.objectValue) {
                if firstString(in: snapshot, keys: ["limitId", "limit_id"]) == "codex" {
                    return snapshot
                }
            }
        }

        if let rateLimits = object["rateLimits"]?.objectValue {
            return rateLimits
        }

        if object["primary"] != nil || object["secondary"] != nil {
            return object
        }

        return nil
    }

    static func parseCodexRateLimitWindow(_ value: JSONValue?) -> CodexRateLimitWindow? {
        guard let object = value?.objectValue else { return nil }
        let percent = firstDouble(in: object, keys: ["usedPercent", "used_percent", "utilization"])
        let duration = firstOptionalInt(in: object, keys: ["windowDurationMins", "window_duration_mins", "windowMinutes"])
        return CodexRateLimitWindow(
            percent: percent,
            resetsAt: parseUnixOrISODate(object["resetsAt"] ?? object["resets_at"]),
            durationMinutes: duration
        )
    }

    static func firstDouble(in object: [String: JSONValue], keys: [String]) -> Double {
        for key in keys {
            if let value = object[key]?.numberValue { return value }
            if let value = object[key]?.stringValue, let doubleValue = Double(value) { return doubleValue }
        }
        return 0
    }

    static func firstOptionalInt(in object: [String: JSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key]?.numberValue { return Int(value) }
            if let value = object[key]?.stringValue, let intValue = Int(value) { return intValue }
        }
        return nil
    }

    static func parseUnixOrISODate(_ value: JSONValue?) -> Date? {
        if let number = value?.numberValue {
            let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value?.stringValue else { return nil }
        if let number = Double(string) {
            let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: string)
    }

    static func usageInfo(from object: [String: JSONValue]) -> UsageInfo? {
        let params = object["params"]?.objectValue ?? object
        let usageKeys = ["usage", "tokenUsage", "token_usage", "totalUsage", "total_usage", "metrics"]
        let usage = firstObject(in: params, keys: [
            "usage", "tokenUsage", "token_usage", "totalUsage", "total_usage", "metrics"
        ]) ?? firstNestedObject(in: .object(params), keys: usageKeys) ?? params

        var inputTokens = firstInt(in: usage, keys: [
            "input_tokens", "inputTokens", "prompt_tokens", "promptTokens"
        ])
        var outputTokens = firstInt(in: usage, keys: [
            "output_tokens", "outputTokens", "completion_tokens", "completionTokens"
        ])
        outputTokens += firstInt(in: usage, keys: [
            "reasoning_output_tokens", "reasoningOutputTokens"
        ])
        let cacheCreationTokens = firstInt(in: usage, keys: [
            "cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWriteInputTokens",
            "cached_creation_tokens", "cachedCreationTokens"
        ])
        let explicitCacheReadTokens = firstInt(in: usage, keys: [
            "cache_read_input_tokens", "cacheReadInputTokens", "cached_input_tokens",
            "cachedInputTokens", "cache_read_tokens", "cacheReadTokens"
        ])
        let cacheReadTokens = explicitCacheReadTokens > 0 ? explicitCacheReadTokens : nestedInputCacheReadTokens(in: usage)

        let total = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        let totalTokens = firstInt(in: usage, keys: ["total_tokens", "totalTokens"])
        if total == 0, totalTokens > 0 {
            inputTokens = totalTokens
        }

        guard inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens > 0 else {
            return nil
        }
        return UsageInfo(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: cacheCreationTokens,
            cacheReadInputTokens: cacheReadTokens
        )
    }

    static func liveTokenUsage(from params: [String: JSONValue]) -> UsageInfo? {
        guard let outputTokens = tokenUsageOutputTokens(from: params),
              outputTokens > 0 else { return nil }
        return UsageInfo(
            inputTokens: 0,
            outputTokens: outputTokens,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0
        )
    }

    static func tokenUsageOutputTokens(from params: [String: JSONValue]) -> Int? {
        let usage = tokenUsageSummary(from: params)
        let outputTokens = firstInt(in: usage, keys: ["outputTokens", "output_tokens"])
        let reasoningOutputTokens = firstInt(in: usage, keys: [
            "reasoningOutputTokens", "reasoning_output_tokens"
        ])
        let total = outputTokens + reasoningOutputTokens
        return total > 0 ? total : nil
    }

    static func tokenUsageTokensUsed(from params: [String: JSONValue]) -> Int? {
        let usage = tokenUsageSummary(from: params)
        let tokensUsed = firstInt(in: usage, keys: [
            "tokensUsed", "tokens_used", "totalTokens", "total_tokens",
            "total", "used", "currentTokens", "current_tokens"
        ])
        return tokensUsed > 0 ? tokensUsed : nil
    }

    static func tokenUsageTokenBudget(from params: [String: JSONValue]) -> Int? {
        let usage = firstObject(in: params, keys: ["tokenUsage", "token_usage"])
            ?? firstNestedObject(in: .object(params), keys: ["tokenUsage", "token_usage"])
            ?? params
        let tokenBudget = firstInt(in: usage, keys: [
            "tokenBudget", "token_budget", "modelContextWindow", "model_context_window"
        ])
        return tokenBudget > 0 ? tokenBudget : nil
    }

    static func tokenUsageSummary(from params: [String: JSONValue]) -> [String: JSONValue] {
        let usage = firstObject(in: params, keys: ["tokenUsage", "token_usage"])
            ?? firstNestedObject(in: .object(params), keys: ["tokenUsage", "token_usage"])
            ?? params
        return firstObject(in: usage, keys: ["last"])
            ?? firstObject(in: usage, keys: ["total"])
            ?? usage
    }

    static func firstObject(in object: [String: JSONValue], keys: [String]) -> [String: JSONValue]? {
        for key in keys {
            if let value = object[key]?.objectValue { return value }
        }
        return nil
    }

    static func firstNestedObject(in value: JSONValue, keys: [String]) -> [String: JSONValue]? {
        if let object = value.objectValue {
            if let direct = firstObject(in: object, keys: keys) { return direct }
            for nested in object.values {
                if let found = firstNestedObject(in: nested, keys: keys) { return found }
            }
        }
        if let array = value.arrayValue {
            for nested in array {
                if let found = firstNestedObject(in: nested, keys: keys) { return found }
            }
        }
        return nil
    }

    static func firstInt(in object: [String: JSONValue], keys: [String]) -> Int {
        for key in keys {
            if let value = object[key]?.numberValue { return Int(value) }
            if let value = object[key]?.stringValue, let intValue = Int(value) { return intValue }
        }
        return 0
    }

    static func nestedInputCacheReadTokens(in usage: [String: JSONValue]) -> Int {
        guard let details = firstObject(in: usage, keys: [
            "input_tokens_details", "inputTokensDetails", "prompt_tokens_details", "promptTokensDetails"
        ]) else { return 0 }
        return firstInt(in: details, keys: [
            "cached_tokens", "cachedTokens", "cache_read_input_tokens", "cacheReadInputTokens"
        ])
    }

    static func usageMessageId(from params: [String: JSONValue], fallback: String?) -> String {
        firstString(in: params, keys: [
            "messageId", "message_id", "responseId", "response_id",
            "turnId", "turn_id", "itemId", "item_id", "id"
        ]) ?? fallback ?? "codex-turn"
    }

    static func claudeTextDelta(_ text: String) -> String {
        jsonString([
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": text]
        ])
    }

    static func claudeThinkingDelta(_ text: String) -> String {
        jsonString([
            "type": "content_block_delta",
            "delta": ["type": "thinking_delta", "thinking": text]
        ])
    }

    static func claudeToolStart(id: String, name: String) -> String {
        jsonString([
            "type": "content_block_start",
            "content_block": ["type": "tool_use", "id": id, "name": name]
        ])
    }

    static func claudeInputDelta(_ input: [String: JSONValue]) -> String {
        let data = (try? JSONEncoder().encode(JSONValue.object(input))) ?? Data("{}".utf8)
        let inputText = String(data: data, encoding: .utf8) ?? "{}"
        return jsonString([
            "type": "content_block_delta",
            "delta": ["type": "input_json_delta", "partial_json": inputText]
        ])
    }

    static func claudeContentBlockStop() -> String {
        jsonString(["type": "content_block_stop"])
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
