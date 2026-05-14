import Foundation
import Testing
@testable import RxCodeCore

@Suite("Agent model persistence")
struct AgentModelTests {
    @Test("AgentModel round trips provider and model id")
    func agentModelRoundTrip() throws {
        let model = AgentModel(provider: .codex, id: "gpt-5.4", displayName: "GPT-5.4", description: "Codex model")
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(AgentModel.self, from: data)

        #expect(decoded.provider == .codex)
        #expect(decoded.id == "gpt-5.4")
        #expect(decoded.key == "codex:gpt-5.4")
    }

    @Test("ChatSession defaults old payloads to Claude Code")
    func oldChatSessionPayloadDefaultsToClaudeCode() throws {
        let id = UUID().uuidString
        let projectId = UUID()
        let json = """
        {
          "id": "\(id)",
          "projectId": "\(projectId.uuidString)",
          "title": "Old Session",
          "messages": [],
          "createdAt": "2026-05-14T00:00:00Z",
          "updatedAt": "2026-05-14T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(ChatSession.self, from: Data(json.utf8))

        #expect(session.agentProvider == .claudeCode)
        #expect(session.summary.agentProvider == .claudeCode)
    }

    @Test("ChatThread summary preserves Codex provider")
    func chatThreadSummaryPreservesProvider() {
        let summary = ChatSession.Summary(
            id: "thread-1",
            projectId: UUID(),
            title: "Codex Thread",
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: false,
            agentProvider: .codex,
            model: "gpt-5.4",
            origin: .codexAppServer
        )

        let row = ChatThread.from(summary, cliSessionId: "thread-1")
        let roundTrip = row.toSummary()

        #expect(roundTrip.agentProvider == .codex)
        #expect(roundTrip.model == "gpt-5.4")
        #expect(roundTrip.origin == .codexAppServer)
    }
}
