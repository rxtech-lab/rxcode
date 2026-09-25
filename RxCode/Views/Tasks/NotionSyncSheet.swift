import RxCodeCore
import SwiftUI

/// Links a project's board to a Notion database, pushes task status to it,
/// and imports its pages as tasks. Opened from the Tasks overview (pick any
/// project) and from a project page (that project preselected).
struct NotionSyncSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var projectId: UUID
    @State private var databases: [NotionDatabase] = []
    @State private var isLoadingDatabases = false
    @State private var loadError: String?
    @State private var statusMessage: String?

    init(projectId: UUID) {
        _projectId = State(initialValue: projectId)
    }

    private var board: TaskBoard { appState.taskBoard(for: projectId) }
    private var link: NotionBoardLink? { board.notion }
    private var isBusy: Bool { appState.notionSyncingProjectIds.contains(projectId) }

    /// The linked database's schema, once the list has loaded.
    private var linkedDatabase: NotionDatabase? {
        guard let link else { return nil }
        return databases.first { NotionID.normalized($0.id) == NotionID.normalized(link.databaseId) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                connectionSection
                if appState.hasNotionToken {
                    linkSection
                    if link != nil {
                        syncSection
                    }
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 540, height: 560)
        .onAppear {
            appState.refreshNotionTokenState()
            if appState.hasNotionToken {
                Task { await loadDatabases() }
            }
        }
        .onChange(of: projectId) { _, _ in
            statusMessage = nil
        }
        .onChange(of: appState.hasNotionToken) { _, connected in
            if !connected { databases = [] }
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            NotionConnectionView {
                Task { await loadDatabases() }
            }
        } header: {
            Text("Notion Account")
        } footer: {
            if !appState.hasNotionToken {
                Text("Choose a relay server, connect with Notion, and pick the pages and databases RxCode may access. With an internal integration token instead, share your database with the integration from its ••• → Connections menu.")
            }
        }
    }

    private var linkSection: some View {
        Section {
            Picker("Project", selection: $projectId) {
                ForEach(appState.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
            .accessibilityIdentifier("notion-project-picker")

            HStack(spacing: 8) {
                Picker("Notion database", selection: databaseSelection) {
                    Text("None").tag(String?.none)
                    if let link, linkedDatabase == nil {
                        // Keep the current link visible before the list loads
                        // or when it's no longer shared with the integration.
                        Text(link.databaseTitle).tag(Optional(NotionID.normalized(link.databaseId)))
                    }
                    ForEach(databases) { database in
                        Text(database.title).tag(Optional(NotionID.normalized(database.id)))
                    }
                }
                .accessibilityIdentifier("notion-database-picker")

                if isLoadingDatabases {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await loadDatabases() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload databases shared with RxCode")
                }
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
            }

            if let database = linkedDatabase {
                if let map = NotionFieldMap(database: database) {
                    LabeledContent("Mapped fields") {
                        Text(map.mappedFields.map { "\($0.field) → \($0.property)" }.joined(separator: "\n"))
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    Label("This database has no title property.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ClaudeTheme.statusWarning)
                }
            }
        } header: {
            Text("Link")
        } footer: {
            Text("Only databases shared with RxCode are listed. Properties are matched by name: Status, Priority, Tags, Version, Milestone, Type, Story and Description. Sync adds any that are missing.")
        }
    }

    private var syncSection: some View {
        Section {
            Toggle("Sync status automatically", isOn: autoSyncBinding)
                .accessibilityIdentifier("notion-auto-sync")

            HStack(spacing: 8) {
                Button {
                    Task { await importPages() }
                } label: {
                    Label("Import from Notion", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("notion-import")

                Button {
                    Task { await push() }
                } label: {
                    Label("Sync to Notion", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("notion-sync")

                Spacer()

                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(isBusy)

            if let error = appState.notionSyncErrors[projectId] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }

            if let lastSyncedAt = link?.lastSyncedAt {
                LabeledContent("Last synced") {
                    Text(lastSyncedAt, style: .relative)
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Sync writes every task as a page with all its fields, adding missing properties to the database, and moves pages of deleted tasks to the Notion trash. A column without a same-named status option uses the status group it falls in: Done → Complete, agent columns and later → In progress, the rest → To-do. Import adds pages not yet on the board.")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Bindings

    private var databaseSelection: Binding<String?> {
        Binding(
            get: { link.map { NotionID.normalized($0.databaseId) } },
            set: { newValue in
                guard let newValue else {
                    appState.unlinkNotion(projectId: projectId)
                    return
                }
                guard let database = databases.first(where: { NotionID.normalized($0.id) == newValue }) else { return }
                appState.linkNotionDatabase(database, projectId: projectId)
                statusMessage = nil
            }
        )
    }

    private var autoSyncBinding: Binding<Bool> {
        Binding(
            get: { link?.autoSync ?? false },
            set: { appState.setNotionAutoSync($0, projectId: projectId) }
        )
    }

    // MARK: - Actions

    private func loadDatabases() async {
        isLoadingDatabases = true
        defer { isLoadingDatabases = false }
        do {
            databases = try await appState.notionDatabases()
            loadError = databases.isEmpty
                ? String(localized: "No databases are shared with RxCode yet. Reconnect and select a database, or share one from its ••• → Connections menu.")
                : nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func push() async {
        let target = projectId
        guard let result = try? await appState.syncTaskBoardToNotion(projectId: target), target == projectId else { return }
        statusMessage = String(localized: "Synced: \(result.created) created, \(result.updated) updated, \(result.archived) archived.")
    }

    private func importPages() async {
        let target = projectId
        guard let result = try? await appState.importFromNotion(projectId: target), target == projectId else { return }
        statusMessage = String(localized: "Imported \(result.added) tasks and \(result.storiesCreated) stories; \(result.skipped) already on the board.")
    }
}

/// Identifies the project a `NotionSyncSheet` opens on.
struct NotionSyncPayload: Identifiable {
    let projectId: UUID
    var id: UUID { projectId }
}

/// The Notion control in a project page's header. Unlinked, it opens the
/// Notion sheet; linked, clicking syncs now and the menu imports, toggles
/// auto-sync, or opens the sheet. A failed sync shows a warning icon with the
/// error in the tooltip.
struct NotionSyncButton: View {
    @Environment(AppState.self) private var appState

    let projectId: UUID
    @Binding var sheet: NotionSyncPayload?

    private var link: NotionBoardLink? { appState.taskBoard(for: projectId).notion }
    private var isSyncing: Bool { appState.notionSyncingProjectIds.contains(projectId) }
    private var error: String? { appState.notionSyncErrors[projectId] }

    var body: some View {
        if let link {
            Menu {
                Button {
                    sync()
                } label: {
                    Label("Sync to Notion", systemImage: "arrow.up.circle")
                }
                Button {
                    Task { _ = try? await appState.importFromNotion(projectId: projectId) }
                } label: {
                    Label("Import from Notion", systemImage: "square.and.arrow.down")
                }
                Divider()
                Toggle("Sync Automatically", isOn: Binding(
                    get: { link.autoSync },
                    set: { appState.setNotionAutoSync($0, projectId: projectId) }
                ))
                Button {
                    sheet = NotionSyncPayload(projectId: projectId)
                } label: {
                    Label("Notion Settings…", systemImage: "gearshape")
                }
            } label: {
                Label {
                    Text(isSyncing ? String(localized: "Syncing…") : link.databaseTitle)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: error == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                        .foregroundStyle(error == nil ? ClaudeTheme.textSecondary : ClaudeTheme.statusWarning)
                        .symbolEffect(.rotate, isActive: isSyncing)
                }
            } primaryAction: {
                sync()
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(isSyncing)
            .help(helpText(for: link))
            .accessibilityIdentifier("task-notion-sync")
        } else {
            Button {
                sheet = NotionSyncPayload(projectId: projectId)
            } label: {
                Label("Notion", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .help("Link this project to a Notion database to sync task status or import pages")
            .accessibilityIdentifier("task-notion-link")
        }
    }

    private func sync() {
        Task { _ = try? await appState.syncTaskBoardToNotion(projectId: projectId) }
    }

    private func helpText(for link: NotionBoardLink) -> String {
        if let error {
            return String(localized: "Notion sync failed: \(error)")
        }
        guard let lastSyncedAt = link.lastSyncedAt else {
            return String(localized: "Sync task status to “\(link.databaseTitle)”")
        }
        let relative = lastSyncedAt.formatted(.relative(presentation: .named))
        return String(localized: "Synced to “\(link.databaseTitle)” \(relative)")
    }
}
