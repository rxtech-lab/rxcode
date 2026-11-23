import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit

// MARK: - Memory Settings Section

struct MemorySettingsSection: View {
    @Environment(AppState.self) private var appState

    @State private var editingDraft: MemoryDraft?
    @State private var showMemoryBrowser = false
    @State private var showMCPServerSettings = false
    @AppStorage(IDEMCPServer.memoryAPIEnabledDefaultsKey) private var memoryMCPServerEnabled = false
    @AppStorage(IDEMCPServer.memoryAPIPortDefaultsKey) private var memoryMCPServerPort = IDEMCPServer.memoryAPIDefaultPort
    @AppStorage(IDEMCPServer.exposedToolsDefaultsKey) private var exposedMCPTools = IDEMCPServer.defaultExposedToolsValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            controlsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editingDraft) { draft in
            MemoryEditorSheet(draft: draft)
        }
        .sheet(isPresented: $showMemoryBrowser) {
            MemoryBrowserSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showMCPServerSettings) {
            MCPServerSettingsSheet(
                isEnabled: $memoryMCPServerEnabled,
                port: $memoryMCPServerPort,
                storedExposedTools: $exposedMCPTools
            )
            .environment(appState)
        }
        .task {
            await configureMCPServer()
        }
        .onChange(of: memoryMCPServerEnabled) { _, _ in
            Task { await configureMCPServer() }
        }
        .onChange(of: memoryMCPServerPort) { _, _ in
            Task { await configureMCPServer() }
        }
        .onChange(of: exposedMCPTools) { _, _ in
            Task { await configureMCPServer() }
        }
        .onChange(of: appState.memoryEnabled) { _, _ in
            Task { await configureMCPServer() }
        }
    }

    private var controlsSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Memory")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Spacer()
                Button {
                    editingDraft = MemoryDraft()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add memory")
                Button {
                    showMemoryBrowser = true
                } label: {
                    Label("Manage", systemImage: "list.bullet.rectangle")
                }
                .help("View and manage saved memories")
            }

            Toggle(isOn: $appState.memoryEnabled) {
                Text("Enable Memory")
            }
            .toggleStyle(.switch)
            .fixedSize()

            Toggle(isOn: $appState.memoryAutoCreateEnabled) {
                Text("Auto-create memories from completed chats")
            }
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(!appState.memoryEnabled)

            Toggle(isOn: $appState.memoryInjectEnabled) {
                Text("Include relevant memories in agent context")
            }
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(!appState.memoryEnabled)

            Picker("Retrieval", selection: $appState.memoryRetrievalMode) {
                ForEach(MemoryRetrievalMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 220, alignment: .leading)
            .disabled(!appState.memoryEnabled || !appState.memoryInjectEnabled)

            Text("Precise returns fewer, stronger matches. Balanced is the default. Aggressive includes more related memories.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(!appState.memoryEnabled || !appState.memoryInjectEnabled)

            Stepper(value: $appState.memoryMaxContextItems, in: 1...12) {
                Text("Context memories: \(appState.memoryMaxContextItems)")
                    .font(.system(size: ClaudeTheme.size(12)))
            }
            .fixedSize()
            .disabled(!appState.memoryEnabled || !appState.memoryInjectEnabled)

            Text("Global memories are shared by all pets and workspaces on this Mac. Project memories stay scoped to their project. Pet memories are available to pets in this workspace. Manage edits or forgets these same records; voice transcript history is separate. No cross-device memory sync is provided.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)

            ClaudeThemeDivider()

            memoryMCPServerSection
        }
    }

    private var memoryMCPServerSection: some View {
        Button {
            showMCPServerSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: ClaudeTheme.size(17)))
                    .foregroundStyle(ClaudeTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Server")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    Text("Choose which RxCode tools are available to other local MCP clients.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if appState.memoryMCPServerRunning {
                    Text("Running")
                        .foregroundStyle(ClaudeTheme.statusSuccess)
                } else {
                    Text("Off")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .font(.system(size: ClaudeTheme.size(11)))
            .padding(12)
            .contentShape(Rectangle())
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func configureMCPServer() async {
        await appState.configureMemoryMCPServer(
            enabled: memoryMCPServerEnabled,
            port: memoryMCPServerPort,
            exposedTools: IDEMCPServer.exposedTools(from: exposedMCPTools)
        )
    }
}

struct MemoryBrowserSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var items: [MemoryItem] = []
    @State private var isLoading = false
    @State private var editingDraft: MemoryDraft?
    @State private var deleteTarget: MemoryItem?
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Memory History")
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                Spacer()
                Button {
                    editingDraft = MemoryDraft()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    showDeleteAllConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete all memories")
                .disabled(items.isEmpty)
                Button("Done") { dismiss() }
            }

            searchSection

            ScrollView {
                memoryList
            }
        }
        .padding(20)
        .frame(width: 640, height: 540)
        .task { await refresh() }
        .onChange(of: appState.memoryRevision) { _, _ in
            Task { await refresh() }
        }
        .sheet(item: $editingDraft) { draft in
            MemoryEditorSheet(draft: draft) {
                Task { await refresh() }
            }
        }
        .alert("Delete Memory?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    Task {
                        await appState.deleteMemoryItem(id: target.id)
                        deleteTarget = nil
                        await refresh()
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This saved memory will be removed from future prompts. Existing conversations may still retain its text. Voice transcript history is managed separately.")
        }
        .alert("Delete All Memories?", isPresented: $showDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                Task {
                    await appState.deleteAllMemoryItems()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete all user-global memories shared by pets and workspaces on this Mac, plus this workspace's project and pet memories? Other workspaces' project memories and voice transcripts are unchanged. This action cannot be undone.")
        }
    }

    private var searchSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search memory", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await refresh() } }
            Button {
                Task { await refresh() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .disabled(isLoading)
        }
    }

    @ViewBuilder
    private var memoryList: some View {
        if items.isEmpty && !isLoading {
            VStack(alignment: .leading, spacing: 6) {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No memories" : "No matching memories")
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                Text("Saved memories are stored locally in SwiftData and embedded on-device.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    memoryRow(item)
                }
            }
        }
    }

    private func memoryRow(_ item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.scope == "pet" ? "pawprint" : (item.scope == "global" ? "globe" : "folder"))
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.content)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(item.kind.capitalized)
                    Text(item.scope.capitalized)
                    if let projectId = item.projectId {
                        Text(projectName(for: projectId))
                    }
                    Text(item.updatedAt, style: .date)
                }
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                editingDraft = MemoryDraft(item: item)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit memory")

            Button(role: .destructive) {
                deleteTarget = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete memory")
        }
        .padding(10)
        .background(ClaudeTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(ClaudeTheme.border, lineWidth: 1)
        )
    }

    private func refresh() async {
        isLoading = true
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items = await appState.allMemoryItems()
        } else {
            items = await appState.searchMemoryItems(query: trimmed, limit: 100, includePet: true).map(\.item)
        }
        isLoading = false
    }

    private func projectName(for id: UUID) -> String {
        appState.projects.first(where: { $0.id == id })?.name ?? id.uuidString
    }
}

struct MemoryDraft: Identifiable {
    let id = UUID()
    var existingId: String?
    var content: String
    var kind: String
    var scope: String
    var projectId: UUID?

    init() {
        self.existingId = nil
        self.content = ""
        self.kind = "fact"
        self.scope = "project"
        self.projectId = nil
    }

    init(item: MemoryItem) {
        self.existingId = item.id
        self.content = item.content
        self.kind = item.kind
        self.scope = item.scope
        self.projectId = item.projectId
    }
}

struct MemoryEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MemoryDraft
    /// Invoked after a successful save so a presenting list can refresh.
    /// Deliberately argument-free: the draft is persisted here, inside the
    /// sheet, so the struct never crosses an escaping async closure boundary.
    private let onSaved: (() -> Void)?

    init(draft: MemoryDraft, onSaved: (() -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.existingId == nil ? "Add Memory" : "Edit Memory")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))

            TextEditor(text: $draft.content)
                .font(.system(size: ClaudeTheme.size(12)))
                .frame(height: 110)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ClaudeTheme.border, lineWidth: 1)
                )

            HStack(spacing: 12) {
                Picker("Kind", selection: $draft.kind) {
                    Text("Fact").tag("fact")
                    Text("Preference").tag("preference")
                    Text("Decision").tag("decision")
                }
                .pickerStyle(.menu)
                .frame(width: 180)

                Picker("Scope", selection: $draft.scope) {
                    Text("Project").tag("project")
                    Text("Global").tag("global")
                    Text("Pet").tag("pet")
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            if draft.scope == "project" {
                Picker("Project", selection: projectSelection) {
                    Text("No project").tag("")
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(project.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        await performSave()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Persists the draft directly through AppState. Kept inside the sheet —
    /// rather than handed back via a `(MemoryDraft) async -> Void` callback —
    /// so the struct is never passed through an escaping async closure.
    private func performSave() async {
        let draft = draft
        if let id = draft.existingId {
            _ = await appState.updateMemoryItem(
                id: id,
                content: draft.content,
                projectId: draft.projectId,
                kind: draft.kind,
                scope: draft.scope
            )
        } else {
            _ = await appState.addMemoryItem(
                content: draft.content,
                projectId: draft.projectId,
                kind: draft.kind,
                scope: draft.scope
            )
        }
        onSaved?()
    }

    private var projectSelection: Binding<String> {
        Binding(
            get: { draft.projectId?.uuidString ?? "" },
            set: { raw in draft.projectId = UUID(uuidString: raw) }
        )
    }
}

// MARK: - Theme Picker Row

struct ThemePickerRow: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(theme.colors.accent)
                    .frame(width: 10, height: 10)
                Text(theme.displayName)
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? ClaudeTheme.sidebarItemHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
