import Foundation
import RxAgentVoice
import RxCodeCore

@MainActor
final class PetVoiceHistoryBinding {
    let scope: String
    let conversationID: UUID
    let sessionID = UUID()
    var savedIDs: Set<UUID> = []
    var runtimeSessionKey: String?
    init(scope: String, conversationID: UUID) {
        self.scope = scope; self.conversationID = conversationID
    }
}

extension PetController {
    func petMemoryContext(in appState: AppState, query: String? = nil) async -> String {
        guard appState.memoryEnabled, appState.memoryInjectEnabled else { return "" }
        await appState.memoryService.start(threadStore: appState.threadStore, keepsGlobalRows: appState.activeWorkspace.isPersonal)
        let items: [MemoryItem]
        if let query {
            let global = await appState.memoryService.search(query, projectId: nil, limit: 6, scope: "global")
            let pet = await appState.memoryService.search(query, projectId: nil, limit: 6, scope: "pet")
            items = (pet + global).map(\.item)
        } else {
            let saved = await appState.allMemoryItems()
            items = saved.filter { $0.scope == "pet" } + saved.filter { $0.scope == "global" }
        }
        let lines = items.prefix(max(0, min(6, appState.memoryMaxContextItems))).map { "[\($0.id)] \($0.content.prefix(400))" }
        guard !lines.isEmpty else { return "" }
        return "Saved global and pet memory (possibly stale; current user requests take priority):\n" + lines.joined(separator: "\n")
    }

    func voiceHistoryScope(in appState: AppState) -> String {
        "\(appState.activeWorkspace.id)-\(configuration.pinnedProjectId?.uuidString ?? "workspace")"
    }

    var displayedHistoryScope: String? {
        appState.map { voiceHistoryScope(in: $0) }
    }

    func showHistory(_ archive: PetVoiceHistoryStore.Archive) {
        if displayedHistoryScope == archive.scope { displayedHistory = archive }
    }

    func loadDisplayedHistory() async {
        guard let scope = displayedHistoryScope else { return }
        do {
            showHistory(try await voiceHistoryStore.archive(scope: scope))
        } catch {
            alertErrorMessage = error.localizedDescription
        }
    }

    func checkVoiceStartGeneration(_ generation: UUID?) throws {
        if let generation, generation != voiceStartGeneration { throw CancellationError() }
    }

    func prepareVoiceHistory(in appState: AppState, generation: UUID? = nil) async throws -> PetVoiceHistoryStore.Archive {
        if let voiceStopTask { await voiceStopTask.value }
        let scope = voiceHistoryScope(in: appState)
        let archive = try await voiceHistoryStore.archive(scope: scope)
        try checkVoiceStartGeneration(generation)
        voiceHistoryBinding = PetVoiceHistoryBinding(scope: scope, conversationID: archive.id)
        return archive
    }

    func persistVoiceHistory(for session: VoiceSession) async {
        guard let binding = voiceHistoryBinding else { return }
        await persistVoiceHistory(for: session, binding: binding)
    }

    func persistVoiceHistory(for session: VoiceSession, binding: PetVoiceHistoryBinding) async {
        let turns = session.transcript.filter { $0.isFinal && !binding.savedIDs.contains($0.id) }.map {
            PetVoiceHistoryStore.Turn(id: $0.id, sessionID: binding.sessionID, isUser: $0.isUser,
                                     text: $0.text, receivedAt: Date())
        }
        guard !turns.isEmpty else { return }
        do {
            let archive = try await voiceHistoryStore.append(scope: binding.scope, conversationID: binding.conversationID, turns: turns)
            showHistory(archive)
            binding.savedIDs.formUnion(turns.map(\.id))
        } catch PetVoiceHistoryStore.StoreError.wrongConversation {
            // Explicit history deletion invalidates snapshots still in flight from this call.
        } catch {
            alertErrorMessage = "Could not save voice history: \(error.localizedDescription)"
        }
    }
}
