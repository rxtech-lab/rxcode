import Foundation
import Observation
import RxCodeCore

@MainActor @Observable
final class CodingAnalyticsRecorder {
    static let shared = CodingAnalyticsRecorder()
    private let store = CodingAnalyticsStore(url: AppSupport.bundleScopedURL.appendingPathComponent("coding-analytics.json"))
    private var activeTurns: Set<UUID> = []
    var error: String?
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "recordCodingAnalytics")
            if !enabled {
                let stopped = activeTurns
                let now = Date()
                activeTurns.removeAll()
                Task {
                    do { try await store.stopRecording(turnIDs: stopped, now: now) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private init() { enabled = UserDefaults.standard.bool(forKey: "recordCodingAnalytics") }

    func begin(threadID: String, projectID: UUID, turnID: UUID, prompt: String?,
               provider: AgentProvider, clientID: String?, model: String?, usageLimits: CodingUsageLimitSnapshot? = nil) async {
        guard enabled else { return }
        activeTurns.insert(turnID)
        do {
            try await store.begin(threadID: threadID, projectID: projectID, turnID: turnID,
                                  prompt: prompt, provider: provider.rawValue, clientID: clientID, model: model, usageLimits: usageLimits)
        } catch { activeTurns.remove(turnID); self.error = error.localizedDescription }
    }

    func update(turnID: UUID, prompt: String? = nil, model: String? = nil, usage: UsageInfo? = nil, usageLimits: CodingUsageLimitSnapshot? = nil) async {
        guard enabled, activeTurns.contains(turnID) else { return }
        do { try await store.update(turnID: turnID, prompt: prompt, model: model, usage: usage, usageLimits: usageLimits) }
        catch { self.error = error.localizedDescription }
    }

    func finish(turnID: UUID, threadID: String, now: Date, usageLimits: CodingUsageLimitSnapshot? = nil) async {
        guard activeTurns.remove(turnID) != nil else { return }
        do { try await store.finish(turnID: turnID, threadID: threadID, usageLimits: usageLimits, now: now) }
        catch { self.error = error.localizedDescription }
    }

    func redirect(from oldID: String, to newID: String) async {
        guard enabled else { return }
        do { try await store.redirect(from: oldID, to: newID) }
        catch { self.error = error.localizedDescription }
    }

    func session(_ id: String) async throws -> CodingAnalyticsSession? { try await store.session(id) }
    func rate(_ id: String, rating: CodingSessionRating?) async throws { try await store.rate(threadID: id, rating: rating) }
    func exportSnapshot() async throws -> (analytics: Data, sessions: [CodingAnalyticsSession]) {
        try await store.exportSnapshot()
    }
    func deleteAll() async throws {
        activeTurns.removeAll()
        try await store.deleteAll()
    }
}
