import Foundation
import RxCodeCore

extension AppState {
    @MainActor
    func handleCreateScheduledTask(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let projectId = try scheduledTaskProjectId(arguments: arguments, sessionKey: sessionKey)
        let name = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cron = arguments["cron_expression"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, !prompt.isEmpty else {
            throw IDEToolError.invalidArguments("A nonempty name and prompt are required.")
        }
        do {
            _ = try CronExpression(cron)
        } catch {
            throw IDEToolError.invalidArguments("Invalid cron_expression: \(error.localizedDescription)")
        }
        let proposal = ScheduledTask(
            projectId: projectId,
            name: name,
            prompt: prompt,
            cronExpression: cron,
            isEnabled: arguments["enabled"]?.boolValue ?? true
        )
        guard let added = await confirmScheduledTaskProposal(proposal) else {
            return jsonTextResult(.object([
                "added": .bool(false),
                "message": .string("The user cancelled the scheduled task. Do not retry unless they ask."),
            ]))
        }
        return jsonTextResult(.object([
            "added": .bool(true),
            "id": .string(added.id.uuidString),
            "project_id": added.projectId.map { .string($0.uuidString) } ?? .null,
            "name": .string(added.name),
            "prompt": .string(added.prompt),
            "cron_expression": .string(added.cronExpression),
            "enabled": .bool(added.isEnabled),
            "next_run_at": added.nextRunDate().map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
        ]))
    }

    /// A scheduled task's project is optional: an explicit `project_id` must
    /// exist, otherwise the current chat's project is used, and a chat outside
    /// any project proposes a task without one.
    private func scheduledTaskProjectId(arguments: JSONValue, sessionKey: String) throws -> UUID? {
        if let explicit = try parseOptionalProjectId(arguments["project_id"]?.stringValue) {
            guard projects.contains(where: { $0.id == explicit }) else {
                throw IDEToolError.invalidArguments("No project with id \(explicit.uuidString). Call ide__get_projects first.")
            }
            return explicit
        }
        let current = threadStore.fetch(id: sessionKey)?.projectId
            ?? allSessionSummaries.first(where: { $0.id == resolveCurrentSessionId(sessionKey) })?.projectId
        return current.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil }
    }
}
