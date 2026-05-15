import Foundation

/// Where the session's message content lives on disk.
public enum SessionOrigin: String, Codable, Sendable {
    /// Legacy RxCode-owned JSON at `~/Library/Application Support/RxCode/sessions/{projectId}/{sid}.json`.
    /// Read-only going forward; will not appear in the CLI's `~/.claude/projects/...` directory.
    case legacyRxCode

    /// Backed by Claude Code CLI's `~/.claude/projects/{enc(cwd)}/{sid}.jsonl`.
    /// Source of truth is the CLI; RxCode keeps RxCode-only metadata in a sidecar.
    case cliBacked

    /// Backed by Codex app-server for execution. RxCode persists a local replay
    /// copy of the rendered messages while using the Codex thread id for turns.
    case codexAppServer

    /// Backed by an Agent Client Protocol agent (OpenCode, Gemini CLI, etc.).
    /// The agent owns its own session storage on disk, but RxCode also keeps a
    /// local replay copy of the rendered messages — the agents do not expose
    /// their logs in a format RxCode can read, so without this copy the chat
    /// appears empty on reopen.
    case acpAgent
}
