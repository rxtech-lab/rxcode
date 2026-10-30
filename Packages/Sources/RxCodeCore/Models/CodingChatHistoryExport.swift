import Foundation

/// Provider-independent transcript schema. Content blocks retain their original order.
public struct CodingChatHistoryExport: Codable, Sendable {
    public struct Content: Codable, Sendable {
        public var type: String
        public var text: String?
        public var toolCallID: String?
        public var name: String?
        public var arguments: [String: JSONValue]?
        public var isError: Bool?
    }

    public struct Message: Codable, Sendable {
        public var id: UUID
        public var role: String
        public var timestamp: Date
        public var content: [Content]
        public var attachments: [AttachmentInfo]
        public var isError: Bool
        public var isStreaming: Bool
        public var durationSeconds: Double?
        public var isCompactBoundary: Bool
    }

    public var schemaVersion = 1
    public var sessionID: String
    public var title: String?
    public var historyStatus: String
    public var messages: [Message]

    public init(sessionID: String, title: String?, messages: [ChatMessage]?) {
        self.sessionID = sessionID
        self.title = title
        historyStatus = messages == nil ? "unavailable" : "available"
        self.messages = (messages ?? []).map { message in
            var content: [Content] = []
            for block in message.blocks {
                if let text = block.text { content.append(.init(type: "text", text: text)) }
                if let call = block.toolCall {
                    content.append(.init(type: "tool_call", toolCallID: call.id, name: call.name, arguments: call.input))
                    if let result = call.result {
                        content.append(.init(type: "tool_result", text: result, toolCallID: call.id, isError: call.isError))
                    }
                }
            }
            return Message(id: message.id, role: message.role.rawValue, timestamp: message.timestamp,
                           content: content, attachments: message.attachmentPaths, isError: message.isError,
                           isStreaming: message.isStreaming, durationSeconds: message.duration,
                           isCompactBoundary: message.isCompactBoundary)
        }
    }
}
