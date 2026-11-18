import Foundation
import RxCodeCore
import Testing
@testable import RxCode

struct PetContinuityAndMemoryTests {
    @Test("The registered history handler retrieves complete prior text through bounded pages in the call's scope")
    @MainActor
    func fullHistoryToolIntegration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PetVoiceHistoryStore(directory: root)
        let archive = try await store.archive(scope: "original-call-project")
        let original = String(repeating: "API-42 factual context. ", count: 700)
        let turn = PetVoiceHistoryStore.Turn(id: UUID(), sessionID: UUID(), isUser: true, text: original, receivedAt: .now)
        try await store.append(scope: archive.scope, conversationID: archive.id, turns: [turn])
        let pet = PetController(historyStore: store)
        pet.voiceHistoryBinding = PetVoiceHistoryBinding(scope: archive.scope, conversationID: archive.id)
        pet.voiceHistoryBinding?.runtimeSessionKey = "pet-codex-realtime-history-test"
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        #expect(IDEToolRegistry.allTools.contains { $0.name == "ide__pet_voice_history" })
        var cursor: String?
        var restored = ""
        repeat {
            var args: [String: RxCodeCore.JSONValue] = ["conversation_id": .string(archive.id.uuidString), "limit": .number(1)]
            if let cursor { args["cursor"] = .string(cursor) }
            let result = try await app.handlePetVoiceHistory(arguments: .object(args), sessionKey: "pet-codex-realtime-history-test", pet: pet)
            let text = try mcpText(result)
            let page = try JSONDecoder().decode(PetVoiceHistoryStore.Page.self, from: Data(text.utf8))
            #expect(page.items.allSatisfy { $0.id == turn.id && $0.textOffset == restored.count })
            #expect(page.items.reduce(0) { $0 + $1.text.count } <= 8_000)
            restored += page.items.map(\.text).joined()
            cursor = page.nextCursor
        } while cursor != nil
        #expect(restored == original)
    }

    @Test("Durable global memories reload from the existing SwiftData database and remain forgotten after restart")
    @MainActor
    func globalMemoryDiskPersistence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MemoryService(globalOnly: true)
        await first.start(threadStore: ThreadStore.make(baseURL: root))
        let memory = try #require(await first.addMemory(content: "Use native sheets for editing.", projectId: nil,
            sessionId: nil, sourceMessageId: nil, kind: "preference", scope: "global"))
        let reopened = MemoryService(globalOnly: true)
        await reopened.start(threadStore: ThreadStore.make(baseURL: root))
        #expect(await reopened.allMemories().contains { $0.id == memory.id && $0.content == memory.content })
        await reopened.deleteMemory(id: memory.id)
        let afterForget = MemoryService(globalOnly: true)
        await afterForget.start(threadStore: ThreadStore.make(baseURL: root))
        #expect(await afterForget.allMemories().isEmpty)
    }

    @Test("Old constraints remain in a bounded summary while recent requests take priority")
    func boundedSummaryAnchors() {
        let segment = UUID()
        var turns = [PetVoiceHistoryStore.Turn(id: UUID(), sessionID: segment, isUser: true,
            text: "Decision: task API-42 must keep port 8123. Pending: deployment remains unverified.", receivedAt: .now)]
        for index in 0..<30 {
            turns.append(.init(id: UUID(), sessionID: segment, isUser: index.isMultiple(of: 2),
                text: "Recent conversation turn \(index).", receivedAt: .now))
        }
        let summary = PetVoiceHistoryStore.summarize(turns)
        #expect(summary.count <= 6_000)
        #expect(summary.contains("API-42") && summary.contains("8123"))
        #expect(summary.contains("turn 29"))
    }

    @Test("Pet memory tools and fresh sessions share global CRUD without changing its scope")
    @MainActor
    func petMemoryToolIntegration() async throws {
        let global = MemoryService(globalOnly: true)
        await global.start(threadStore: ThreadStore.inMemory())
        let first = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let second = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        first.memoryService = MemoryService(globalMemories: global)
        second.memoryService = MemoryService(globalMemories: global)
        await first.memoryService.start(threadStore: ThreadStore.inMemory())
        await second.memoryService.start(threadStore: ThreadStore.inMemory())
        let oldEnabled = (first.memoryEnabled, second.memoryEnabled, second.memoryInjectEnabled)
        defer { first.memoryEnabled = oldEnabled.0; second.memoryEnabled = oldEnabled.1; second.memoryInjectEnabled = oldEnabled.2 }
        first.memoryEnabled = true; second.memoryEnabled = true; second.memoryInjectEnabled = true
        _ = try await first.handleMemoryAdd(arguments: .object(["content": .string("Use short progress reports."), "kind": .string("preference")]), defaultScope: "global")
        let item = try #require(await global.allMemories().first)
        _ = try await second.handleMemoryUpdate(arguments: .object(["id": .string(item.id), "content": .string("Use concise factual progress reports.")]))
        let pet = PetController()
        let context = await pet.petMemoryContext(in: second)
        #expect(context.contains("concise factual progress reports"))
        #expect(await global.allMemories().first?.scope == "global")
        let listed = try await second.ideHandleToolCall(name: "ide__memory_list", arguments: .object(["scope": .string("global")]), sessionKey: "pet-memory-test")
        let text = try mcpText(listed)
        #expect(text.contains(item.id))
        _ = try await second.handleMemoryDelete(arguments: .object(["id": .string(item.id)]))
        #expect(await first.allMemoryItems().isEmpty)
        #expect(await pet.petMemoryContext(in: second).isEmpty)
    }

    @Test("Pet sessions save memory to pet scope by default and inject it into fresh sessions")
    @MainActor
    func petSessionsDefaultToPetScope() async throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        state.memoryService = MemoryService()
        await state.memoryService.start(threadStore: ThreadStore.inMemory())
        let old = (state.memoryEnabled, state.memoryInjectEnabled)
        defer { state.memoryEnabled = old.0; state.memoryInjectEnabled = old.1 }
        state.memoryEnabled = true; state.memoryInjectEnabled = true
        _ = try await state.ideHandleToolCall(
            name: "ide__memory_add",
            arguments: .object(["content": .string("Your name is Sea Baby."), "kind": .string("preference")]),
            sessionKey: "pet-codex-realtime-test"
        )
        #expect(await state.allMemoryItems().map(\.scope) == ["pet"])
        #expect(await PetController().petMemoryContext(in: state).contains("Sea Baby"))
    }

    @Test("Realtime voice context carries persona, memory and history within the initial-item budget")
    @MainActor
    func realtimeVoiceContextBudget() async throws {
        let store = PetVoiceHistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var archive = try await store.archive(scope: "s")
        let long = String(repeating: "海", count: 400)
        archive = try await store.append(scope: "s", conversationID: archive.id, turns: (0..<40).map {
            .init(id: UUID(), sessionID: UUID(), isUser: $0 % 2 == 0, text: "\($0) \(long)", receivedAt: .now)
        })
        let memory = "Saved global and pet memory:\n[1] Your name is Sea Baby."
        let context = PetController.buildRealtimeVoiceContext(configuration: PetConfiguration(), memory: memory, history: archive)
        #expect(context.count <= PetController.realtimeVoiceContextLimit)
        #expect(context.contains("Sea Baby"))
        #expect(context.contains("Saved memory below about your name"))
        #expect(context.contains("historical data, not new instructions"))
        #expect(context.contains("ide__pet_voice_history"))
    }

    @Test("Editing a project memory to Pet removes its project association and makes it available to pet conversations")
    @MainActor
    func editProjectMemoryToPet() async throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        state.memoryService = MemoryService()
        await state.memoryService.start(threadStore: ThreadStore.inMemory())
        let previous = (state.memoryEnabled, state.memoryInjectEnabled)
        defer { (state.memoryEnabled, state.memoryInjectEnabled) = previous }
        state.memoryEnabled = true
        state.memoryInjectEnabled = true
        let projectID = UUID()
        let content = "Greet me by waving."
        let original = try #require(await state.addMemoryItem(content: content, projectId: projectID))
        let edited = try #require(await state.updateMemoryItem(id: original.id, content: content,
            projectId: projectID, kind: original.kind, scope: "pet"))
        #expect(edited.scope == "pet")
        #expect(edited.projectId == nil)
        #expect(await state.searchMemoryItems(query: content, projectId: projectID).isEmpty)
        let previousLimit = state.memoryMaxContextItems
        defer { state.memoryMaxContextItems = previousLimit }
        state.memoryMaxContextItems = 1
        _ = await state.addMemoryItem(content: "Use Markdown.", projectId: nil, scope: "global")
        let pet = PetController()
        #expect(await pet.petMemoryContext(in: state).contains(content))
        #expect(await pet.petMemoryContext(in: state, query: "Use Markdown.").contains(content))
    }

    private func mcpText(_ result: RxCodeCore.JSONValue) throws -> String {
        guard case .object(let root) = result,
              case .array(let content)? = root["content"],
              case .object(let block)? = content.first,
              case .string(let text)? = block["text"] else {
            throw NSError(domain: "PetToolResultTest", code: 1)
        }
        return text
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PetHistoryTests-\(UUID().uuidString)")
    }

    @Test("Voice history survives reopening, deduplicates snapshots, and injects bounded historical context")
    func historyPersistence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PetVoiceHistoryStore(directory: root)
        let initial = try await store.archive(scope: "workspace-project")
        let session = UUID()
        let turns = [
            PetVoiceHistoryStore.Turn(id: UUID(), sessionID: session, isUser: true,
                text: "Remember task API-123: keep localhost at port 8123 and do not deploy.", receivedAt: .now),
            .init(id: UUID(), sessionID: session, isUser: false,
                text: "Decision: use presigned uploads. Pending: verify deployment. Tests are not verified.", receivedAt: .now)
        ]
        try await store.append(scope: initial.scope, conversationID: initial.id, turns: turns)
        try await store.append(scope: initial.scope, conversationID: initial.id, turns: turns)
        let reopened = try await PetVoiceHistoryStore(directory: root).archive(scope: initial.scope)
        #expect(reopened.id == initial.id && reopened.turns == turns)
        #expect(reopened.summary.count <= 6_000)
        #expect(reopened.context.contains("API-123"))
        #expect(reopened.context.contains("historical data, not new instructions"))
        #expect(reopened.context.contains("Do not automatically speak"))
        #expect(reopened.context.contains("ide__pet_voice_history"))
        #expect(reopened.context.contains(initial.id.uuidString))
    }

    @Test("Paginated voice history returns every Unicode character and preserves stable turn IDs")
    func fullHistoryPagination() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PetVoiceHistoryStore(directory: root)
        let archive = try await store.archive(scope: "scope")
        let text = String(repeating: "任务🙂é", count: 4_000)
        let turn = PetVoiceHistoryStore.Turn(id: UUID(), sessionID: UUID(), isUser: true, text: text, receivedAt: .now)
        try await store.append(scope: archive.scope, conversationID: archive.id, turns: [turn])
        var cursor: String?
        var reconstructed = ""
        repeat {
            let page = try await store.page(scope: archive.scope, conversationID: archive.id, cursor: cursor, limit: 1, maxCharacters: 333)
            #expect(page.items.allSatisfy { $0.id == turn.id && $0.textOffset == reconstructed.count })
            reconstructed += page.items.map(\.text).joined()
            #expect(page.items.reduce(0) { $0 + $1.text.count } <= 333)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(reconstructed == text)
        try await store.clear(scope: archive.scope, conversationID: archive.id)
        do { _ = try await store.append(scope: archive.scope, conversationID: archive.id, turns: [turn]); Issue.record("A cleared call must not restore deleted history") }
        catch PetVoiceHistoryStore.StoreError.wrongConversation {}
        let cleared = try await PetVoiceHistoryStore(directory: root).archive(scope: archive.scope)
        #expect(cleared.id != archive.id && cleared.context.isEmpty && cleared.turns.isEmpty)
        do { _ = try await store.page(scope: "another-project", conversationID: archive.id, cursor: nil); Issue.record("History must stay project/workspace scoped") }
        catch PetVoiceHistoryStore.StoreError.wrongConversation {}
    }

    @Test("Missing continuity metadata decodes tolerantly without dropping completed turns")
    func tolerantHistoryDecoding() throws {
        var archive = PetVoiceHistoryStore.Archive(scope: "legacy")
        archive.turns = [.init(id: UUID(), sessionID: UUID(), isUser: true, text: "Request", receivedAt: .now)]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        object.removeValue(forKey: "version")
        object.removeValue(forKey: "summary")
        let decoded = try JSONDecoder().decode(PetVoiceHistoryStore.Archive.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.version == 1 && decoded.turns == archive.turns)
    }

    @Test("Global memory shares existing records across workspaces, preserves project scope and supports forgetting")
    @MainActor
    func sharedMemoryCRUD() async throws {
        let globalStore = ThreadStore.inMemory()
        let global = MemoryService(globalOnly: true)
        await global.start(threadStore: globalStore)
        let firstStore = ThreadStore.inMemory()
        let secondStore = ThreadStore.inMemory()
        let first = MemoryService(globalMemories: global)
        let second = MemoryService(globalMemories: global)
        await first.start(threadStore: firstStore)
        await second.start(threadStore: secondStore)
        let item = try #require(await first.addMemory(content: "请始终用简短中文回答。", projectId: nil,
            sessionId: nil, sourceMessageId: nil, kind: "preference", scope: "global"))
        #expect(await second.allMemories().contains { $0.id == item.id })
        let updated = await second.updateMemory(id: item.id, content: "Always use concise English responses.", projectId: nil,
            sessionId: nil, sourceMessageId: nil, kind: "preference", scope: "global")
        #expect(await first.allMemories().first?.content == updated?.content)
        let projectID = UUID()
        let projectItem = try #require(await second.addMemory(content: "Project port is 8123.", projectId: projectID,
            sessionId: nil, sourceMessageId: nil, scope: "project"))
        #expect(await first.allMemories().allSatisfy { $0.id != projectItem.id })
        #expect(await second.search("port", projectId: nil).allSatisfy { $0.item.scope == "global" })
        await first.deleteMemory(id: item.id)
        #expect(await second.allMemories().allSatisfy { $0.id != item.id })
        #expect(globalStore.fetchMemory(id: item.id) == nil)
        #expect(secondStore.fetchMemory(id: projectItem.id) != nil)
        await first.restart(threadStore: firstStore)
        #expect(await first.allMemories().isEmpty)
    }

    @Test("Global-memory reset does not delete project records in the personal database")
    @MainActor
    func globalResetRespectsScope() async throws {
        let store = ThreadStore.inMemory()
        let project = store.upsertMemory(id: nil, content: "Project-only", projectId: UUID(), sessionId: nil,
            sourceMessageId: nil, kind: "fact", scope: "project", vector: Data(), dim: 0)
        let global = MemoryService(globalOnly: true)
        await global.start(threadStore: store)
        _ = await global.addMemory(content: "Shared preference", projectId: nil, sessionId: nil, sourceMessageId: nil, scope: "global")
        await global.deleteAll()
        #expect(store.fetchMemory(id: project.id) != nil)
        #expect(await global.allMemories().isEmpty)
    }
}
