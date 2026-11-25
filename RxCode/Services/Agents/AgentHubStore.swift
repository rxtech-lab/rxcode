import Foundation
import RxCodeCore
import os

/// JSON persistence for the Agents tab, under the workspace's
/// `agents/` folder: profiles, memory notes, jobs and remote-access policy.
actor AgentHubStore {
    struct Contents: Sendable {
        var agents: [AgentProfile] = []
        var memory: [AgentMemoryNote] = []
        var jobs: [AgentJob] = []
        var remoteAccess = AgentRemoteAccessPolicy()
    }

    let rootURL: URL
    private let logger = Logger(subsystem: "com.claudework", category: "AgentHubStore")

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private var agentsURL: URL { rootURL.appendingPathComponent("agents.json") }
    private var memoryURL: URL { rootURL.appendingPathComponent("agent_memory.json") }
    private var jobsURL: URL { rootURL.appendingPathComponent("agent_jobs.json") }
    private var remoteAccessURL: URL { rootURL.appendingPathComponent("remote_access.json") }

    /// The folder an agent works in when it has no working directory of its own.
    nonisolated func homeURL(for agentId: UUID) -> URL {
        rootURL.appendingPathComponent(agentId.uuidString, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    func load() -> Contents {
        Contents(
            agents: decode([AgentProfile].self, from: agentsURL) ?? [],
            memory: AgentMemoryNote.pruned(decode([AgentMemoryNote].self, from: memoryURL) ?? []),
            jobs: AgentJob.pruned(AgentJob.restored(decode([AgentJob].self, from: jobsURL) ?? [])),
            remoteAccess: decode(AgentRemoteAccessPolicy.self, from: remoteAccessURL) ?? AgentRemoteAccessPolicy()
        )
    }

    func save(_ contents: Contents) {
        encode(contents.agents, to: agentsURL)
        encode(contents.memory, to: memoryURL)
        encode(contents.jobs, to: jobsURL)
        encode(contents.remoteAccess, to: remoteAccessURL)
    }

    /// Creates the agent's home folder and returns its path.
    func ensureHome(for agentId: UUID) throws -> String {
        let url = homeURL(for: agentId)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Removes everything stored for a deleted agent.
    func removeFolder(for agentId: UUID) {
        let url = rootURL.appendingPathComponent(agentId.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            logger.error("Failed to decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Keep the unreadable file for recovery instead of overwriting it.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupted-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }
}
