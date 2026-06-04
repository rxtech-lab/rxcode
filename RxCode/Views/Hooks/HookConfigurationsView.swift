import RxCodeCore
import SwiftUI

/// Modal sheet for editing a project's lifecycle hooks. Mirrors
/// `RunConfigurationsView`: left list grouped by trigger, right detail form.
struct HookConfigurationsView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) var dismiss

    let project: Project

    @State private var draft: [HookProfile] = []
    @State private var selectedId: UUID?

    private var selectedIndex: Int? {
        guard let id = selectedId else { return nil }
        return draft.firstIndex { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                hookList
                    .frame(minWidth: 220, idealWidth: 240, maxHeight: .infinity)
                detailPane
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 560, idealHeight: 620)
        .task {
            await appState.ensureHookProfilesLoaded(for: project.id)
            draft = appState.hookProfiles(for: project.id)
            selectedId = draft.first?.id
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Project Hooks")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var hookList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                addMenu
                Button { deleteSelected() } label: { Image(systemName: "minus") }
                    .disabled(selectedId == nil)
                    .help("Delete Hook")
                Button { duplicateSelected() } label: { Image(systemName: "doc.on.doc") }
                    .disabled(selectedId == nil)
                    .help("Duplicate Hook")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)

            Divider()

            if draft.isEmpty {
                VStack {
                    Spacer()
                    Text("No hooks yet")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    Text("Click + to add one.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedId) {
                    ForEach(HookTrigger.allCases, id: \.self) { trigger in
                        let hooks = draft.filter { $0.trigger == trigger }
                        if !hooks.isEmpty {
                            Section(trigger.displayName) {
                                ForEach(hooks) { hook in
                                    hookRow(hook)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(ClaudeTheme.surfaceSecondary.opacity(0.4))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let idx = selectedIndex {
            HookProfileDetailForm(hook: $draft[idx], project: project)
                .id(draft[idx].id)
        } else {
            VStack {
                Spacer()
                Text("Select or add a hook to edit")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { applyAndDismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func hookRow(_ hook: HookProfile) -> some View {
        HStack {
            Image(systemName: iconName(for: hook.type))
                .foregroundStyle(hook.enabled ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
            Text(hook.name.isEmpty ? "Untitled" : hook.name)
                .foregroundStyle(hook.enabled ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
        }
        .tag(hook.id)
    }

    /// SF Symbol per type — matches `RunConfigurationsView.iconName(for:)`.
    private func iconName(for type: RunProfileType) -> String {
        switch type {
        case .xcode: return "hammer.fill"
        case .make: return "wrench.and.screwdriver.fill"
        case .bash: return "terminal"
        case .packageScript: return "shippingbox.fill"
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(HookTrigger.allCases, id: \.self) { trigger in
                Button {
                    addHook(trigger: trigger)
                } label: {
                    Label(trigger.displayName, systemImage: "bolt.horizontal.circle")
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add Hook")
    }

    // MARK: - Actions

    private func addHook(trigger: HookTrigger) {
        let new = HookProfile(
            projectId: project.id,
            name: "New Hook",
            trigger: trigger
        )
        draft.append(new)
        selectedId = new.id
    }

    private func deleteSelected() {
        guard let idx = selectedIndex else { return }
        let removed = draft.remove(at: idx)
        if selectedId == removed.id {
            selectedId = draft.indices.contains(idx) ? draft[idx].id : draft.last?.id
        }
    }

    private func duplicateSelected() {
        guard let idx = selectedIndex else { return }
        var copy = draft[idx]
        copy.id = UUID()
        copy.name += " (copy)"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        draft.insert(copy, at: idx + 1)
        selectedId = copy.id
    }

    private func applyAndDismiss() {
        let now = Date()
        let stamped = draft.map { hook -> HookProfile in
            var h = hook
            h.updatedAt = now
            return h
        }
        appState.setHookProfiles(stamped, for: project.id)
        dismiss()
    }
}
