import Foundation
import SwiftData
import RxCodeCore
import os

// MARK: - Container & Schema

/// Schema definition and the container factories that back `ThreadStore`.
@MainActor
extension ThreadStore {
    /// The full SwiftData schema for the thread store, shared by the file-backed
    /// (`make`) and in-memory (`inMemory`, used by tests) factories.
    static var schema: Schema {
        Schema([
            ChatThread.self,
            TodoSnapshot.self,
            ThreadFileEdit.self,
            QueuedMessageRecord.self,
            PlanDecisionRecord.self,
            ThreadSummaryRecord.self,
            BranchBriefingRecord.self,
            ThreadEmbeddingChunk.self,
            MemoryRecord.self,
            HookStatusRecord.self,
            HookCardRecord.self,
            CustomMenuItemRecord.self
        ])
    }

    /// In-memory store over the full schema, for tests.
    static func inMemory() -> ThreadStore {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ThreadStore(container: container)
    }

    /// Convenience initializer creating its own `ModelContainer` rooted at the
    /// app's Application Support directory.
    static func make(baseURL: URL = AppSupport.bundleScopedURL) -> ThreadStore {
        let schema = Self.schema
        let url = Self.storeURL(baseURL: baseURL)
        let config = ModelConfiguration(schema: schema, url: url)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let store = ThreadStore(container: container)
            // Sweep hook cards left mid-run by a previous launch so they don't
            // rebuild as a perpetual spinner.
            store.finalizeInterruptedHooks()
            store.finalizeInterruptedHookCards()
            store.finalizeInterruptedCompletionChecks()
            return store
        } catch {
            // Fall back to an in-memory container so the app still launches.
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try! ModelContainer(for: schema, configurations: [fallback])
            let store = ThreadStore(container: container)
            store.logger.error("Falling back to in-memory ChatThread store: \(error.localizedDescription)")
            return store
        }
    }

    private static func storeURL(baseURL: URL) -> URL {
        let fm = FileManager.default
        let dir = baseURL
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("threads.store")
    }
}
