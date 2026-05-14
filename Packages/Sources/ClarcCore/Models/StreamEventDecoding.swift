import Foundation

// MARK: - StreamEvent Decodable

extension StreamEvent: Decodable {
    private enum RootCodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RootCodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "system":
            let event = try SystemEvent(from: decoder)
            self = .system(event)
        case "assistant":
            let message = try AssistantMessage(from: decoder)
            self = .assistant(message)
        case "user":
            let message = try UserMessage(from: decoder)
            self = .user(message)
        case "result":
            let event = try ResultEvent(from: decoder)
            self = .result(event)
        case "rate_limit_event":
            let info = try RateLimitInfo(from: decoder)
            self = .rateLimitEvent(info)
        default:
            let rawData = try JSONEncoder().encode(JSONValue(from: decoder))
            let rawString = String(data: rawData, encoding: .utf8) ?? "{\"type\": \"\(type)\"}"
            self = .unknown(rawString)
        }
    }
}

// MARK: - SystemEvent Decodable

extension SystemEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case subtype
        case sessionId = "session_id"
        case tools
        case model
        case claudeCodeVersion = "claude_code_version"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.subtype = try container.decodeIfPresent(String.self, forKey: .subtype) ?? "unknown"
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.tools = try container.decodeIfPresent([String].self, forKey: .tools)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.claudeCodeVersion = try container.decodeIfPresent(String.self, forKey: .claudeCodeVersion)
    }
}

// MARK: - AssistantMessage Decodable

extension AssistantMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case message
    }

    private enum MessageCodingKeys: String, CodingKey {
        case id
        case role
        case content
        case usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messageContainer = try container.nestedContainer(
            keyedBy: MessageCodingKeys.self,
            forKey: .message
        )
        self.id = try messageContainer.decodeIfPresent(String.self, forKey: .id)
        self.role = try messageContainer.decode(String.self, forKey: .role)
        self.content = try messageContainer.decode([ContentBlock].self, forKey: .content)
        self.usage = try messageContainer.decodeIfPresent(UsageInfo.self, forKey: .usage)
    }
}

// MARK: - ContentBlock Decodable

extension ContentBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case thinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decodeIfPresent([String: JSONValue].self, forKey: .input) ?? [:]
            self = .toolUse(id: id, name: name, input: input)
        case "thinking":
            let thinking = try container.decode(String.self, forKey: .thinking)
            self = .thinking(thinking)
        default:
            let text = try container.decodeIfPresent(String.self, forKey: .text)
                ?? "[Unknown content block: \(type)]"
            self = .text(text)
        }
    }
}

// MARK: - UserMessage Decodable

extension UserMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case message
    }

    private enum MessageCodingKeys: String, CodingKey {
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }

    private struct ContentBlockItem: Decodable {
        let type: String?
        let text: String?
        let content: String?
        let toolUseId: String?

        private enum CodingKeys: String, CodingKey {
            case type, text, content
            case toolUseId = "tool_use_id"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messageContainer = try container.nestedContainer(
            keyedBy: MessageCodingKeys.self,
            forKey: .message
        )
        self.isError = try messageContainer.decodeIfPresent(Bool.self, forKey: .isError) ?? false

        var blockToolUseId: String?
        if let stringContent = try? messageContainer.decode(String.self, forKey: .content) {
            self.content = stringContent
        } else if let blocks = try? messageContainer.decode([ContentBlockItem].self, forKey: .content) {
            let texts = blocks.compactMap { $0.type == "tool_result" ? $0.content : ($0.text ?? $0.content) }
            self.content = texts.joined(separator: "\n")
            blockToolUseId = blocks.first(where: { $0.toolUseId != nil })?.toolUseId
        } else {
            self.content = ""
        }
        self.toolUseId = try messageContainer.decodeIfPresent(String.self, forKey: .toolUseId) ?? blockToolUseId
    }
}

// MARK: - UsageInfo Decodable

extension UsageInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        self.cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }
}

// MARK: - ContextWindowInfo Decodable

extension ContextWindowInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case remainingPercentage = "remaining_percentage"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercentage = try container.decodeIfPresent(Double.self, forKey: .usedPercentage) ?? 0
        self.remainingPercentage = try container.decodeIfPresent(Double.self, forKey: .remainingPercentage) ?? 0
    }
}

// MARK: - ResultEvent Decodable

extension ResultEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case totalCostUsd = "total_cost_usd"
        case sessionId = "session_id"
        case isError = "is_error"
        case totalTurns = "total_turns"
        case usage
        case contextWindow = "context_window"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        self.totalCostUsd = try container.decodeIfPresent(Double.self, forKey: .totalCostUsd)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        self.totalTurns = try container.decodeIfPresent(Int.self, forKey: .totalTurns)
        self.usage = try container.decodeIfPresent(UsageInfo.self, forKey: .usage)
        self.contextWindow = try container.decodeIfPresent(ContextWindowInfo.self, forKey: .contextWindow)
    }
}

// MARK: - RateLimitInfo Decodable

extension RateLimitInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case rateLimitInfo = "rate_limit_info"
        case status
        case retrySec = "retry_sec"
    }

    private enum NestedCodingKeys: String, CodingKey {
        case status
        case retrySec = "retry_sec"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.nestedContainer(keyedBy: NestedCodingKeys.self, forKey: .rateLimitInfo) {
            self.status = try nested.decode(String.self, forKey: .status)
            self.retrySec = try nested.decodeIfPresent(Double.self, forKey: .retrySec)
        } else {
            self.status = try container.decode(String.self, forKey: .status)
            self.retrySec = try container.decodeIfPresent(Double.self, forKey: .retrySec)
        }
    }
}
