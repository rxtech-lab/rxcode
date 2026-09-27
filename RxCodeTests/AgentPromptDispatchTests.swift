import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class AgentPromptDispatchTests: XCTestCase {
    func testConfiguredPromptsReachClaudeAndCodex() async throws {
        let previousGlobalPrompt = UserDefaults.standard.object(forKey: "globalAgentPrompt")
        defer {
            if let previousGlobalPrompt {
                UserDefaults.standard.set(previousGlobalPrompt, forKey: "globalAgentPrompt")
            } else {
                UserDefaults.standard.removeObject(forKey: "globalAgentPrompt")
            }
        }
        UserDefaults.standard.set("Use English.", forKey: "globalAgentPrompt")

        let appState = AppState(startBackgroundServices: false)
        var project = Project(name: "Prompts", path: "/tmp/rxcode-prompts-\(UUID().uuidString)")
        project.customPrompt = "Use SwiftUI."
        appState.projects = [project]

        for provider in [AgentProvider.claudeCode, .codex] {
            let backend = MockAgentBackend(provider: provider)
            appState.agentBackendOverrides[provider] = backend
            _ = try await appState.sendCrossProject(
                projectId: project.id,
                threadId: nil,
                prompt: "Build the view.",
                agentProvider: provider,
                waitForResponse: true,
                timeoutSeconds: 10,
                includeIDEMCP: false
            )

            let requests = await backend.receivedRequests
            let request = try XCTUnwrap(requests.last)
            let context = provider == .claudeCode ? request.extraSystemPrompt : request.prompt
            XCTAssertTrue(context?.contains("# Global instructions\n\nUse English.") == true)
            XCTAssertTrue(context?.contains("# Project instructions\n\nUse SwiftUI.") == true)
            XCTAssertTrue(request.prompt.hasSuffix("Build the view."))
        }
    }
}
