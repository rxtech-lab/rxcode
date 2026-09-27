import Foundation
import Testing
@testable import RxCodeCore

@Suite("Scheduled tasks")
struct ScheduledTaskTests {

    @Test("A task's model survives a round trip")
    func agentRoundTrips() throws {
        let task = ScheduledTask(
            projectId: UUID(),
            name: "Nightly",
            prompt: "Check dependencies",
            cronExpression: "0 9 * * *",
            agent: TaskAgentConfig(provider: .claudeCode, model: "opus")
        )
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: data)
        #expect(decoded.agent == task.agent)
    }

    @Test("Records without a model decode as unassigned")
    func missingAgentDecodesUnassigned() throws {
        let json = """
        {"id":"\(UUID().uuidString)","projectId":"\(UUID().uuidString)","name":"Old","prompt":"p","cronExpression":"* * * * *"}
        """
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        #expect(!decoded.agent.isAssigned)
    }

    @Test("A task without a project survives a round trip")
    func missingProjectRoundTrips() throws {
        let task = ScheduledTask(name: "Morning", prompt: "Summarize my day", cronExpression: "0 9 * * *")
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: data)
        #expect(decoded.projectId == nil)
        #expect(decoded.id == task.id)
    }

    @Test("Records with a project keep it")
    func projectDecodes() throws {
        let projectId = UUID()
        let json = """
        {"id":"\(UUID().uuidString)","projectId":"\(projectId.uuidString)","name":"Old","prompt":"p","cronExpression":"* * * * *"}
        """
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
        #expect(decoded.projectId == projectId)
    }
}
