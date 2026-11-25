import Foundation

/// One durable thing an agent remembers: a preference, fact, decision or note.
/// Every note is injected into the agent's context on each turn, so the
/// agent keeps its memory across conversations, subagents and devices.
public struct AgentMemoryNote: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var agentId: UUID
    public var content: String
    public var kind: Kind
    /// Who wrote the note: the user in the UI, or the agent through its tool.
    public var source: Source
    public var createdAt: Date
    public var updatedAt: Date

    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case preference
        case fact
        case decision
        case note

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .note
        }

        public var displayName: LocalizedStringResource {
            switch self {
            case .preference: "Preference"
            case .fact: "Fact"
            case .decision: "Decision"
            case .note: "Note"
            }
        }

        public var systemImage: String {
            switch self {
            case .preference: "heart"
            case .fact: "info.circle"
            case .decision: "checkmark.seal"
            case .note: "note.text"
            }
        }
    }

    public enum Source: String, Codable, Sendable, Hashable {
        case user
        case agent

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .agent
        }
    }

    /// Longest note content kept.
    public static let contentLimit = 4000
    /// Notes kept per agent; the oldest are dropped first.
    public static let perAgentLimit = 200

    public init(
        id: UUID = UUID(),
        agentId: UUID,
        content: String,
        kind: Kind = .note,
        source: Source = .user,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.agentId = agentId
        self.content = String(content.prefix(Self.contentLimit))
        self.kind = kind
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, agentId, content, kind, source, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        agentId = try c.decode(UUID.self, forKey: .agentId)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .note
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .agent
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? .now
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
    }

    /// Keeps at most `perAgentLimit` notes for each agent, newest first.
    public static func pruned(_ notes: [AgentMemoryNote]) -> [AgentMemoryNote] {
        var counts: [UUID: Int] = [:]
        return notes.sorted { $0.updatedAt > $1.updatedAt }.filter { note in
            counts[note.agentId, default: 0] += 1
            return counts[note.agentId, default: 0] <= perAgentLimit
        }
    }
}
