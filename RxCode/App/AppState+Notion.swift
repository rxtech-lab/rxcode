import Foundation
import os
import RxCodeCore

/// A relay that can run "Connect with Notion".
struct NotionRelayOption: Identifiable, Hashable {
    var name: String
    /// HTTP base derived from the relay's WebSocket URL.
    var baseURL: URL
    var id: URL { baseURL }
}

/// What a push to Notion changed.
struct NotionPushResult: Sendable, Hashable {
    var created = 0
    var updated = 0
    var archived = 0
}

/// Task-board sync with Notion: link a project's board to a Notion database,
/// push every task as a page of it (status, priority, tags, version, …), and
/// import the database's pages as tasks.
///
/// The board stays the source of truth for a push; an import only adds pages
/// that aren't linked to a task yet. Link state lives on `TaskBoard.notion`.
extension AppState {

    // MARK: - Connection state

    /// Mirrors the stored credential into observable state.
    func refreshNotionTokenState() {
        let credential = NotionService.storedCredential()
        hasNotionToken = credential != nil
        notionWorkspaceName = credential?.workspaceName
        notionRelayURL = credential?.relayURL
    }

    // MARK: - Relays

    private static let notionRelayKey = "notionOAuthRelayURL"

    /// The relays "Connect with Notion" can go through: the ones configured in
    /// Settings → Mobile, then hosted presets not already among them, deduped
    /// by their HTTP base.
    func notionRelayOptions() -> [NotionRelayOption] {
        var options: [NotionRelayOption] = []
        func add(name: String, url: String) {
            guard let parsed = URL(string: url),
                  let base = NotionOAuthSession.httpBaseURL(forRelay: parsed),
                  !options.contains(where: { $0.baseURL == base })
            else { return }
            options.append(NotionRelayOption(name: name, baseURL: base))
        }
        let saved = MobileSyncService.shared.savedRelayServers
        for server in saved.filter(\.isEnabled) + saved.filter({ !$0.isEnabled }) {
            add(name: server.name, url: server.url)
        }
        for preset in RelayPresetCatalog.shared.presets {
            add(name: preset.name, url: preset.url)
        }
        return options
    }

    /// The relay last used to connect, if still offered, else the first one.
    func preferredNotionRelay(in options: [NotionRelayOption]) -> NotionRelayOption? {
        let last = workspaceDefaults.string(for: Self.notionRelayKey)
        return options.first { $0.baseURL.absoluteString == last } ?? options.first
    }

    /// A display name for the relay a credential was granted through.
    func notionRelayName(for relayURL: String) -> String {
        notionRelayOptions().first { $0.baseURL.absoluteString == relayURL }?.name
            ?? URL(string: relayURL)?.host
            ?? relayURL
    }

    // MARK: - Connecting

    /// "Connect with Notion" through `relay`, which exchanges the code with
    /// its integration's secret and returns the token encrypted to this
    /// attempt's key. The relay is checked first, so one without Notion
    /// credentials fails here instead of on an error page mid sign-in.
    func connectNotionWithOAuth(relay: NotionRelayOption) async throws {
        guard await notion.relaySupportsNotion(relay.baseURL) else {
            throw NotionError.relayUnsupported(relay.name)
        }
        let session = NotionOAuthSession()
        let callback = try await NotionWebAuthSession().authenticate(
            url: session.startURL(relayBaseURL: relay.baseURL)
        )
        var credential = try session.credential(from: callback)
        credential.relayURL = relay.baseURL.absoluteString
        try await storeNotionCredential(credential)
        workspaceDefaults.set(relay.baseURL.absoluteString, for: Self.notionRelayKey)
        logger.info("[Notion] connected with OAuth via \(relay.baseURL.absoluteString, privacy: .public)")
    }

    /// Stores a pasted internal integration token, or disconnects when
    /// `token` is empty.
    func setNotionToken(_ token: String?) async throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await storeNotionCredential(trimmed.isEmpty ? nil : NotionCredential(accessToken: trimmed))
    }

    func disconnectNotion() async throws {
        try await storeNotionCredential(nil)
    }

    private func storeNotionCredential(_ credential: NotionCredential?) async throws {
        try NotionService.storeCredential(credential)
        await notion.resetCredential()
        refreshNotionTokenState()
    }

    private func requireNotionConnection() throws {
        guard hasNotionToken || NotionService.storedCredential() != nil else {
            hasNotionToken = false
            throw NotionError.missingToken
        }
    }

    // MARK: - Linking

    /// The databases shared with the integration, for the database picker.
    func notionDatabases() async throws -> [NotionDatabase] {
        try requireNotionConnection()
        return try await notion.searchDatabases()
    }

    /// Links a project's board to `database`. Relinking the same database
    /// keeps its page links; choosing a different one starts fresh, so tasks
    /// are pushed as new pages there.
    func linkNotionDatabase(_ database: NotionDatabase, projectId: UUID) {
        updateBoard(projectId) { board in
            if let existing = board.notion,
               NotionID.normalized(existing.databaseId) == NotionID.normalized(database.id) {
                board.notion?.databaseTitle = database.title
            } else {
                board.notion = NotionBoardLink(
                    databaseId: database.id,
                    databaseTitle: database.title,
                    autoSync: board.notion?.autoSync ?? false
                )
            }
        }
        notionSyncErrors[projectId] = nil
    }

    func unlinkNotion(projectId: UUID) {
        notionAutoSyncTasks.removeValue(forKey: projectId)?.cancel()
        updateBoard(projectId) { $0.notion = nil }
        notionSyncErrors[projectId] = nil
    }

    func setNotionAutoSync(_ enabled: Bool, projectId: UUID) {
        updateBoard(projectId) { $0.notion?.autoSync = enabled }
        if enabled {
            scheduleNotionAutoSync(projectId: projectId)
        } else {
            notionAutoSyncTasks.removeValue(forKey: projectId)?.cancel()
        }
    }

    // MARK: - Data source

    /// The linked data source's schema. A link saved with a database id
    /// (before data sources) is repointed at the data source it resolved to,
    /// keeping its page links.
    private func resolveNotionDataSource(link: NotionBoardLink, projectId: UUID) async throws -> NotionDatabase {
        let dataSource = try await notion.database(id: link.databaseId)
        if NotionID.normalized(dataSource.id) != NotionID.normalized(link.databaseId) {
            updateBoard(projectId) { board in
                guard let current = board.notion,
                      NotionID.normalized(current.databaseId) == NotionID.normalized(link.databaseId)
                else { return }
                board.notion?.databaseId = dataSource.id
            }
        }
        return dataSource
    }

    // MARK: - Push

    /// Writes the project's tasks to its linked database: new tasks become
    /// pages, changed ones are updated, and pages of deleted tasks are moved
    /// to the Notion trash. Unchanged tasks are skipped by fingerprint.
    ///
    /// Progress is recorded even when a request fails partway, so a retry
    /// doesn't create duplicate pages.
    @discardableResult
    func syncTaskBoardToNotion(projectId: UUID) async throws -> NotionPushResult {
        guard !notionSyncingProjectIds.contains(projectId) else { return NotionPushResult() }
        notionSyncingProjectIds.insert(projectId)
        defer { notionSyncingProjectIds.remove(projectId) }

        do {
            let result = try await pushToNotion(projectId: projectId)
            notionSyncErrors[projectId] = nil
            return result
        } catch {
            notionSyncErrors[projectId] = error.localizedDescription
            throw error
        }
    }

    private func pushToNotion(projectId: UUID) async throws -> NotionPushResult {
        try requireNotionConnection()
        guard let storedLink = taskBoard(for: projectId).notion else { throw NotionError.notLinked }
        var database = try await resolveNotionDataSource(link: storedLink, projectId: projectId)
        guard NotionFieldMap(database: database) != nil else { throw NotionError.unsupportedDatabase }
        // Every task field gets a property, so nothing is silently skipped.
        let missing = NotionFieldMap.missingProperties(in: database, board: taskBoard(for: projectId))
        if !missing.isEmpty {
            database = try await notion.addProperties(missing, toDataSource: database.id)
            logger.info("[Notion] added properties \(missing.keys.sorted().joined(separator: ", "), privacy: .public)")
        }
        guard let map = NotionFieldMap(database: database) else { throw NotionError.unsupportedDatabase }
        let link = taskBoard(for: projectId).notion ?? storedLink

        // Read after the schema fetch so the push reflects the latest edits.
        let board = taskBoard(for: projectId)
        var result = NotionPushResult()
        var written: [String: NotionPageLink] = [:]
        var removed: [String] = []
        var failure: Error?

        do {
            for task in board.tasks {
                let properties = NotionTaskMapper.properties(for: task, board: board, map: map)
                let fingerprint = NotionTaskMapper.fingerprint(properties)
                let existing = link.page(for: task.id)
                if existing?.fingerprint == fingerprint { continue }

                var pageId = existing?.pageId
                if let current = pageId {
                    do {
                        try await notion.updatePage(id: current, properties: properties)
                        result.updated += 1
                    } catch let error as NotionError where error.isMissingPage {
                        pageId = nil
                    }
                }
                if pageId == nil {
                    pageId = try await notion.createPage(databaseId: link.databaseId, properties: properties)
                    result.created += 1
                }
                if let pageId {
                    written[task.id.uuidString] = NotionPageLink(pageId: pageId, fingerprint: fingerprint)
                }
            }

            let liveIds = Set(board.tasks.map(\.id.uuidString))
            for (taskId, page) in link.pages where !liveIds.contains(taskId) {
                do {
                    try await notion.archivePage(id: page.pageId)
                    result.archived += 1
                } catch let error as NotionError where error.isMissingPage {
                    // Already gone in Notion.
                }
                removed.append(taskId)
            }
        } catch {
            failure = error
        }

        updateBoard(projectId) { board in
            // The link may have been removed or repointed while requests ran.
            guard let current = board.notion,
                  NotionID.normalized(current.databaseId) == NotionID.normalized(link.databaseId)
            else { return }
            board.notion?.pages.merge(written) { _, new in new }
            for taskId in removed { board.notion?.pages.removeValue(forKey: taskId) }
            if failure == nil { board.notion?.lastSyncedAt = Date() }
        }

        if let failure { throw failure }
        logger.info("[Notion] pushed project \(projectId, privacy: .public): \(result.created) created, \(result.updated) updated, \(result.archived) archived")
        return result
    }

    /// Pushes a few seconds after the last board change, while auto-sync is
    /// on. Waits out a sync already running instead of overlapping it.
    func scheduleNotionAutoSync(projectId: UUID) {
        guard taskBoard(for: projectId).notion?.autoSync == true else { return }
        notionAutoSyncTasks[projectId]?.cancel()
        notionAutoSyncTasks[projectId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            while self.notionSyncingProjectIds.contains(projectId) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            // Detach before syncing so a newer change schedules its own run
            // instead of cancelling this one mid-request.
            self.notionAutoSyncTasks[projectId] = nil
            do {
                try await self.syncTaskBoardToNotion(projectId: projectId)
            } catch {
                self.logger.error("[Notion] auto-sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Import

    /// Adds the linked database's pages to the project's board as tasks.
    /// Pages already linked to a task are skipped; see
    /// `TaskBoard.applyNotionImport`.
    func importFromNotion(projectId: UUID) async throws -> NotionImportResult {
        guard !notionSyncingProjectIds.contains(projectId) else { return NotionImportResult() }
        notionSyncingProjectIds.insert(projectId)
        defer { notionSyncingProjectIds.remove(projectId) }

        do {
            try requireNotionConnection()
            guard let storedLink = taskBoard(for: projectId).notion else { throw NotionError.notLinked }
            let database = try await resolveNotionDataSource(link: storedLink, projectId: projectId)
            guard let map = NotionFieldMap(database: database) else { throw NotionError.unsupportedDatabase }
            let link = taskBoard(for: projectId).notion ?? storedLink
            let pages = try await notion.queryPages(databaseId: link.databaseId)
            let items = pages.compactMap { NotionTaskMapper.importedItem(from: $0, map: map) }

            var result = NotionImportResult()
            let agent = defaultTaskAgent()
            updateBoard(projectId) { board in
                guard let current = board.notion,
                      NotionID.normalized(current.databaseId) == NotionID.normalized(link.databaseId)
                else { return }
                result = board.applyNotionImport(items, projectId: projectId, link: current, agent: agent)
            }
            notionSyncErrors[projectId] = nil
            logger.info("[Notion] imported into project \(projectId, privacy: .public): \(result.added) added, \(result.skipped) skipped")
            return result
        } catch {
            notionSyncErrors[projectId] = error.localizedDescription
            throw error
        }
    }
}
