import SwiftUI
import UIKit
import RxCodeCore
import RxCodeSync

/// Modal sheet for composing a new thread. Captures the prompt + config knobs
/// (branch, model, permission mode), fires `requestNewSession` on submit, then
/// watches the session list for the freshly-created summary and dismisses,
/// handing the new session ID back to the caller so it can navigate.
struct NewThreadSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    let onSessionCreated: (String) -> Void

    @State private var text: String = ""
    @State private var isSubmitting = false
    @State private var awaitingFromSessionIDs: Set<String>?
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmed.isEmpty && !isSubmitting
    }

    private var projectName: String {
        state.projects.first(where: { $0.id == projectID })?.name ?? "this project"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    composer
                    NewThreadConfigStrip(projectID: projectID)
                        .environmentObject(state)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("New Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFocused = true
            }
        }
        .onChange(of: state.sessions.map(\.id)) { _, _ in
            attemptJumpToNewSession()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(accentGradient)
                .padding(.bottom, 2)

            Text("What should we build in \(projectName)?")
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)

            Text("Describe a task, paste a snippet, or ask a question.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - Composer (multiline input with embedded send)

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(
                "Describe what to build…",
                text: $text,
                axis: .vertical
            )
            .lineLimit(4 ... 14)
            .textFieldStyle(.plain)
            .font(.body)
            .focused($isFocused)
            .disabled(isSubmitting)
            .submitLabel(.return)
            .accessibilityIdentifier("new-thread-input")

            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 4)
    }

    private var sendButton: some View {
        Button {
            submit()
        } label: {
            ZStack {
                Circle()
                    .fill(canSend ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.18)))
                    .frame(width: 36, height: 36)

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canSend ? Color.white : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityIdentifier("new-thread-send")
        .animation(.easeInOut(duration: 0.15), value: canSend)
        .animation(.easeInOut(duration: 0.15), value: isSubmitting)
    }

    // MARK: - Style helpers

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.6, blue: 0.4),
                Color(red: 0.85, green: 0.5, blue: 0.55),
                Color(red: 0.65, green: 0.5, blue: 0.7),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Actions

    private func submit() {
        guard canSend else { return }
        let body = trimmed
        isSubmitting = true
        isFocused = false
        awaitingFromSessionIDs = Set(
            state.sessions
                .filter { $0.projectId == projectID }
                .map { $0.id }
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            await state.requestNewSession(projectID: projectID, initialText: body)
        }
    }

    private func attemptJumpToNewSession() {
        guard let existing = awaitingFromSessionIDs else { return }
        let newest = state.sessions
            .filter { $0.projectId == projectID && !existing.contains($0.id) }
            .max(by: { $0.updatedAt < $1.updatedAt })
        guard let newest else { return }
        awaitingFromSessionIDs = nil
        onSessionCreated(newest.id)
        dismiss()
    }
}

// MARK: - New Thread Config Strip

/// Compact configuration row showing the same three knobs the desktop exposes
/// for a new session: branch (with create/switch menu), permission mode, and
/// model. Picker changes mutate the desktop's default settings via the
/// existing `settings_update` payload — the new thread inherits whatever is
/// selected when the user sends the first message.
struct NewThreadConfigStrip: View {
    @EnvironmentObject private var state: MobileAppState
    let projectID: UUID
    @State private var showingCreateBranch = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Settings")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }

            HStack(spacing: 8) {
                branchMenu
                permissionMenu
                modelMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingCreateBranch) {
            CreateBranchSheet(
                projectID: projectID,
                baseBranch: state.projectBranches[projectID]
            )
            .environmentObject(state)
        }
        .alert(
            "Branch operation failed",
            isPresented: branchOpErrorBinding,
            actions: {
                Button("OK", role: .cancel) { state.clearBranchOpError() }
            },
            message: {
                Text(state.lastBranchOpError ?? "")
            }
        )
    }

    private var branchOpErrorBinding: Binding<Bool> {
        Binding(
            get: { state.lastBranchOpError != nil },
            set: { if !$0 { state.clearBranchOpError() } }
        )
    }

    // MARK: Branch

    private var branchList: [String] {
        state.availableBranchesByProject[projectID] ?? []
    }

    private var currentBranch: String? {
        state.projectBranches[projectID]
    }

    private var branchMenu: some View {
        Menu {
            if !branchList.isEmpty {
                Section("Switch branch") {
                    ForEach(branchList, id: \.self) { name in
                        Button {
                            Task { await state.switchProjectBranch(projectID: projectID, branch: name) }
                        } label: {
                            HStack {
                                Image(systemName: name == currentBranch ? "checkmark" : "arrow.triangle.branch")
                                Text(name)
                            }
                        }
                        .disabled(name == currentBranch)
                    }
                }
            }
            Button {
                showingCreateBranch = true
            } label: {
                Label("Create new branch…", systemImage: "plus")
            }
        } label: {
            chipLabel(
                icon: "arrow.triangle.branch",
                title: currentBranch ?? "No branch"
            )
        }
    }

    // MARK: Model

    private var availableModels: [AgentModel] {
        state.desktopSettings?.availableModels ?? []
    }

    private var groupedModels: [(provider: AgentProvider, models: [AgentModel])] {
        var seen: [AgentProvider] = []
        for model in availableModels where !seen.contains(model.provider) {
            seen.append(model.provider)
        }
        return seen.map { provider in
            (provider, availableModels.filter { $0.provider == provider })
        }
    }

    private var selectedModelLabel: String {
        guard let settings = state.desktopSettings else { return "Model" }
        if let match = availableModels.first(where: {
            $0.provider == settings.selectedAgentProvider && $0.id == settings.selectedModel
        }) {
            return match.displayName
        }
        return settings.selectedModel.isEmpty ? settings.selectedAgentProvider.displayName : settings.selectedModel
    }

    private var modelMenu: some View {
        Menu {
            ForEach(groupedModels, id: \.provider) { group in
                Section(group.provider.displayName) {
                    ForEach(group.models, id: \.key) { model in
                        Button {
                            applyModel(model)
                        } label: {
                            let isSelected = state.desktopSettings?.selectedAgentProvider == model.provider
                                && state.desktopSettings?.selectedModel == model.id
                            HStack {
                                Text(model.displayName)
                                if isSelected {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            if availableModels.isEmpty {
                Text("No models available")
            }
        } label: {
            chipLabel(icon: "cpu", title: selectedModelLabel)
        }
        .disabled(availableModels.isEmpty)
    }

    private func applyModel(_ model: AgentModel) {
        Task {
            await state.updateDesktopSettings(
                MobileSettingsUpdatePayload(
                    selectedAgentProvider: model.provider,
                    selectedModel: model.id
                )
            )
        }
    }

    // MARK: Permission Mode

    private var permissionMenu: some View {
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button {
                    applyPermissionMode(mode)
                } label: {
                    HStack {
                        Label(mode.displayName, systemImage: mode.systemImage)
                        if state.desktopSettings?.permissionMode == mode {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            let mode = state.desktopSettings?.permissionMode ?? .default
            chipLabel(icon: mode.systemImage, title: mode.displayName)
        }
    }

    private func applyPermissionMode(_ mode: PermissionMode) {
        Task {
            await state.updateDesktopSettings(
                MobileSettingsUpdatePayload(permissionMode: mode)
            )
        }
    }

    // MARK: Chip

    private func chipLabel(icon: String, title: String, showsChevron: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Create Branch Sheet

struct CreateBranchSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let baseBranch: String?

    @State private var branchText: String = "rxcode/"
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        branchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if trimmed.isEmpty { return "Branch name is required." }
        if trimmed.hasSuffix("/") { return "Branch name cannot end with “/”." }
        if trimmed == "rxcode/" { return "Add a branch name after the prefix." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("rxcode/feature-name", text: $branchText)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .focused($isFocused)
                        .disabled(isSubmitting)
                        .submitLabel(.go)
                        .onSubmit(submit)
                } header: {
                    Text("Branch name")
                } footer: {
                    if let base = baseBranch {
                        Text("Created from \(base)")
                    } else {
                        Text("Created from the project's current branch")
                    }
                }

                if let error = validationError, !trimmed.isEmpty, trimmed != "rxcode/" {
                    Section { Text(error).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Create branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Create")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(validationError != nil || isSubmitting)
                }
            }
            .onAppear {
                DispatchQueue.main.async { isFocused = true }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        guard validationError == nil else { return }
        isSubmitting = true
        let name = trimmed
        Task {
            await state.createProjectBranch(projectID: projectID, branch: name)
            isSubmitting = false
            dismiss()
        }
    }
}
