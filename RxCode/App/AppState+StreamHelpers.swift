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
        switch agentProvider {
        case .claudeCode:
            return await claude.consumeStderr(for: streamId)
        case .codex:
            return await codex.consumeStderr(for: streamId)
        case .acp:
            return await acp.consumeStderr(for: streamId)
        }
    }

    // MARK: - Editing File Snapshot Capture

    /// Detects Edit/MultiEdit/Write tool_use events and reads the target
    /// file's current contents **synchronously** so the pre-edit snapshot is
    /// captured before the CLI starts executing the tool. The result is cached
    /// on `state.editingFileSnapshots` keyed by absolute path; only the FIRST
    /// tool_use per (session, path) reads — later edits in the same thread
    /// keep diffing against the original snapshot. A previous implementation
    /// did this read on a detached task, which lost the race for large files
    /// and produced an `originalContent` identical to `modifiedContent`,
    /// collapsing the diff. Reading synchronously here is safe because we run
    /// at content_block_stop / assistant tool_use arrival — the CLI has only
    /// just finished emitting the tool_use and has not yet executed it.
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

        for path in paths where state.editingFileSnapshots[path] == nil {
            state.editingFileSnapshots[path] = try? String(contentsOfFile: path, encoding: .utf8)
        }
    }
}
