import Foundation

/// Where the session's message content lives on disk.
public enum SessionOrigin: String, Codable, Sendable {
    /// Legacy RxCode-owned JSON at `~/Library/Application Support/RxCode/sessions/{projectId}/{sid}.json`.
    /// Read-only going forward; will not appear in the CLI's `~/.claude/projects/...` directory.
    case legacyRxCode

    /// Backed by Claude Code CLI's `~/.claude/projects/{enc(cwd)}/{sid}.jsonl`.
    /// Source of truth is the CLI; RxCode keeps RxCode-only metadata in a sidecar.
    case cliBacked
}
