import Foundation
import RxCodeChatKit
import RxCodeCore
import RxCodeSync

extension AppState {
    func finalizeAgentStream(agentProvider: AgentProvider, streamId: UUID) async {
        // Claude needs an explicit stdin close before finalize so the CLI
        // sees EOF; other backends manage stdin internally.
        if agentProvider == .claudeCode {
            await claude.closeStdin(streamId: streamId)
        }
        await backend(for: agentProvider).finalize(streamId: streamId)
    }

    /// Release the per-session IDE-MCP listener allocated for ACP turns.
    /// Safe to call for non-ACP providers (no-op).
    func releaseIDESession(sessionKey: String) async {
        await ideMCPServer.release(sessionKey: sessionKey)
    }

    func consumeAgentStderr(agentProvider: AgentProvider, streamId: UUID) async -> String? {
        await backend(for: agentProvider).consumeStderr(for: streamId)
    }

    static func formatModelId(_ raw: String) -> String {
        let lower = raw.lowercased()
        let family: String
        if lower.contains("opus") { family = "Opus" }
        else if lower.contains("sonnet") { family = "Sonnet" }
        else if lower.contains("haiku") { family = "Haiku" }
        else { return raw }

        let parts = lower.components(separatedBy: CharacterSet(charactersIn: "-"))
        if let idx = parts.firstIndex(where: { $0 == family.lowercased() }),
           idx + 1 < parts.count
        {
            let ver = parts[(idx + 1)...].prefix(2).filter { $0.allSatisfy(\.isNumber) }
            if !ver.isEmpty { return "\(family) \(ver.joined(separator: "."))" }
        }
        return family
    }

    // MARK: - Editing File Snapshot Capture

    /// Detects Edit/MultiEdit/Write tool_use events and reads the target
    /// file's current contents **synchronously** so the pre-edit snapshot is
    /// captured before the CLI starts executing the tool. The result is cached
    /// on `state.editingFileSnapshots` keyed by absolute path; only the FIRST
    /// tool_use per (session, path) updates `editingFileSnapshots` — later edits
    /// in the same thread keep diffing against the original snapshot, while
    /// `state.latestStepSnapshots` always records the immediate pre-step content
    /// so external concurrent edits on the same file can be detected.
    ///
    /// Handles both the Claude/Anthropic shape (`file_path` in input) and the
    /// Codex `changes: [{ path, diff }]` shape. Tools that don't touch files
    /// (Bash, Read, etc.) are skipped.
    nonisolated static func captureEditingFileSnapshot(
        toolName: String,
        input: [String: JSONValue],
        state: inout SessionStreamState
    ) {
        let nameLower = toolName.lowercased()
        let editToolNames: Set<String> = ["edit", "multiedit", "multi_edit", "write"]
        guard editToolNames.contains(nameLower) else { return }

        var paths: [String] = []
        if let path = input["file_path"]?.stringValue {
            paths.append(path)
        }
        if nameLower == "edit", let changes = input["changes"]?.arrayValue {
            for change in changes {
                if let obj = change.objectValue,
                   let path = obj["path"]?.stringValue {
                    paths.append(path)
                }
            }
        }

        for path in paths {
            let content = try? String(contentsOfFile: path, encoding: .utf8)
            if state.editingFileSnapshots[path] == nil {
                state.editingFileSnapshots[path] = content
            }
            state.latestStepSnapshots[path] = content
        }
    }
}
