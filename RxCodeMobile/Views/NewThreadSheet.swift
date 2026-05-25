import SwiftUI
import UIKit
import RxCodeCore
import RxCodeSync
import TipKit

/// Modal sheet for composing a new thread. Captures the prompt + config knobs
/// (branch, model, permission mode), fires `requestNewSession` on submit, then
/// watches the session list for the freshly-created summary and dismisses,
/// handing the new session ID back to the caller so it can navigate.
struct NewThreadSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    var preferredBranch: String? = nil
    let onSessionCreated: (String) -> Void

    @State private var text: String = ""
    @State private var isSubmitting = false
    @State private var awaitingFromSessionIDs: Set<String>?
    @FocusState private var isFocused: Bool

    // Per-thread agent config. Seeded once from the desktop's current settings,
    // then applied only to the thread this sheet creates (no longer mutates the
    // desktop's global defaults).
    @State private var planModeEnabled = false
    @State private var selectedProvider: AgentProvider?
    @State private var selectedModelID: String?
    @State private var selectedPermissionMode: PermissionMode = .default
    @State private var didSeedConfig = false

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmed.isEmpty && !isSubmitting
    }

    private var projectName: String {
        state.projects.first(where: { $0.id == projectID })?.name ?? String(localized: "this project")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    composer
                    NewThreadConfigStrip(
                        projectID: projectID,
                        preferredBranch: preferredBranch,
                        selectedProvider: $selectedProvider,
                        selectedModelID: $selectedModelID,
                        selectedPermissionMode: $selectedPermissionMode,
                        planModeEnabled: $planModeEnabled
                    )
                    .environmentObject(state)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .mobileDismissesKeyboardOnScroll(.interactively)
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
        .mobileSheetPresentation()
        .onAppear {
            seedConfigIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFocused = true
            }
        }
        .onChange(of: state.desktopSettings) { _, _ in
            seedConfigIfNeeded()
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

    /// Copy the desktop's current agent config into local state once it is
    /// available. Runs on appear and again if the snapshot arrives afterwards.
    private func seedConfigIfNeeded() {
        guard !didSeedConfig, let settings = state.desktopSettings else { return }
        didSeedConfig = true
        selectedProvider = settings.selectedAgentProvider
        selectedModelID = settings.selectedModel
        selectedPermissionMode = settings.permissionMode
    }

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
            // Make sure the desktop has parked the picked branch's worktree
            // before the new session spawns; otherwise the two payloads race
            // and the thread lands on the project root instead of the
            // selected branch's worktree.
            await state.waitForPendingBranchOps()
            await state.requestNewSession(
                projectID: projectID,
                initialText: body,
                agentProvider: selectedProvider,
                model: selectedModelID,
                permissionMode: selectedPermissionMode,
                planMode: planModeEnabled
            )
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

/// Compact configuration row for a new thread: branch (create/switch menu),
/// permission mode, model, and a plan-mode toggle. Model/permission/plan picks
/// are bound to the parent sheet's local state and travel in the
/// `new_session_request` payload — they apply only to the created thread and no
/// longer mutate the desktop's global defaults.
struct NewThreadConfigStrip: View {
    @EnvironmentObject private var state: MobileAppState
    let projectID: UUID
    var preferredBranch: String? = nil
    @Binding var selectedProvider: AgentProvider?
    @Binding var selectedModelID: String?
    @Binding var selectedPermissionMode: PermissionMode
    @Binding var planModeEnabled: Bool
    @State private var showingCreateBranch = false
    @State private var didApplyPreferredBranch = false
    /// Optimistically tracks the branch the user picked in this sheet so the
    /// chip label updates immediately. The desktop's `projectBranches` snapshot
    /// only reflects the main repo's branch, which doesn't change when the
    /// thread is parked on a worktree — without this local override the chip
    /// would stay stuck on the initial branch.
    @State private var pickedBranch: String?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Settings")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }

            GlassEffectContainer(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    branchMenu
                    modelMenu
                    permissionMenu
                    planToggleChip
                }
            }
        }
        .sheet(isPresented: $showingCreateBranch) {
            CreateBranchSheet(
                projectID: projectID,
                baseBranch: state.projectBranches[projectID]
            )
            .environmentObject(state)
        }
        .onAppear(perform: applyPreferredBranchIfNeeded)
        .onChange(of: state.projectBranches[projectID]) { _, _ in
            applyPreferredBranchIfNeeded()
        }
        .onChange(of: state.lastBranchOpError) { _, newValue in
            // Revert the optimistic pick so the chip falls back to the
            // desktop's actual current branch when the op failed.
            if newValue != nil { pickedBranch = nil }
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
        pickedBranch ?? state.projectBranches[projectID] ?? preferredBranch
    }

    /// When the sheet was opened from a context that knows the desired branch
    /// (e.g. the briefing detail screen), ask the desktop to switch to it so
    /// the new thread spawns on the right branch. Only fires once per sheet
    /// presentation, and only when the desktop is on a different branch.
    private func applyPreferredBranchIfNeeded() {
        guard !didApplyPreferredBranch, let target = preferredBranch else { return }
        let actual = state.projectBranches[projectID]
        guard actual != nil, actual != target else {
            if actual == target { didApplyPreferredBranch = true }
            return
        }
        didApplyPreferredBranch = true
        pickedBranch = target
        Task { await state.switchProjectBranch(projectID: projectID, branch: target) }
    }

    private var branchMenu: some View {
        Menu {
            if !branchList.isEmpty {
                Section("Switch branch") {
                    ForEach(branchList, id: \.self) { name in
                        Button {
                            pickedBranch = name
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

    /// Flat model list synced from the desktop. Used only as a fallback when the
    /// paired desktop is too old to send structured `modelSections`.
    private var flatModels: [AgentModel] {
        state.desktopSettings?.availableModels ?? []
    }

    /// Model picker sections mirroring the desktop layout: Claude Code, Codex,
    /// and one section per enabled ACP client. Falls back to grouping the flat
    /// model list by provider when paired with a desktop that predates
    /// `modelSections` in the sync protocol.
    private var modelSections: [AgentModelSection] {
        if let sections = state.desktopSettings?.modelSections, !sections.isEmpty {
            return sections
        }
        var seen: [AgentProvider] = []
        for model in flatModels where !seen.contains(model.provider) {
            seen.append(model.provider)
        }
        return seen.map { provider in
            AgentModelSection(
                id: provider.rawValue,
                title: provider.displayNameText,
                provider: provider,
                models: flatModels.filter { $0.provider == provider }
            )
        }
    }

    private var allModels: [AgentModel] {
        modelSections.flatMap(\.models)
    }

    private var selectedModelLabel: String {
        if let match = allModels.first(where: {
            $0.provider == selectedProvider && $0.id == selectedModelID
        }) {
            return match.displayName
        }
        if let id = selectedModelID, !id.isEmpty { return id }
        return selectedProvider?.displayNameText ?? String(localized: "Model")
    }

    private var modelMenu: some View {
        Menu {
            ForEach(modelSections) { section in
                Section(section.title) {
                    ForEach(section.models, id: \.key) { model in
                        Button {
                            applyModel(model)
                        } label: {
                            let isSelected = selectedProvider == model.provider
                                && selectedModelID == model.id
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
            if allModels.isEmpty {
                Text("No models available")
            }
        } label: {
            chipLabel(icon: "cpu", title: selectedModelLabel)
        }
        .disabled(allModels.isEmpty)
        .popoverTip(MobileTips.AgentSelectionTip(), arrowEdge: .top)
    }

    private func applyModel(_ model: AgentModel) {
        selectedProvider = model.provider
        selectedModelID = model.id
    }

    // MARK: Permission Mode

    private var permissionMenu: some View {
        Menu {
            // `.plan` is intentionally excluded — plan mode is a dedicated
            // toggle, matching the desktop's permission dropdown.
            ForEach(PermissionMode.allCases.filter { $0 != .plan }, id: \.self) { mode in
                Button {
                    selectedPermissionMode = mode
                } label: {
                    HStack {
                        Label {
                            Text(mode.displayName)
                        } icon: {
                            Image(systemName: mode.systemImage)
                        }
                        if selectedPermissionMode == mode {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            chipLabel(icon: selectedPermissionMode.systemImage, title: selectedPermissionMode.displayNameText)
        }
    }

    // MARK: Plan Mode

    /// Dedicated plan-mode toggle, orthogonal to the permission menu. Mirrors the
    /// desktop's `sessionPlanMode` boolean — when on, the thread starts with the
    /// CLI in `--permission-mode plan`.
    private var planToggleChip: some View {
        Button {
            planModeEnabled.toggle()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            chipLabel(
                icon: PermissionMode.plan.systemImage,
                title: PermissionMode.plan.displayNameText,
                showsChevron: false,
                active: planModeEnabled
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plan mode")
        .accessibilityValue(Text(planModeAccessibilityValue))
        .popoverTip(MobileTips.PlanModeTip(), arrowEdge: .top)
    }

    private var planModeAccessibilityValue: LocalizedStringResource {
        planModeEnabled ? "On" : "Off"
    }

    // MARK: Chip

    private func chipLabel(
        icon: String,
        title: String,
        showsChevron: Bool = true,
        active: Bool = false
    ) -> some View {
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
        .foregroundStyle(active ? Color.white : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .glassEffect(
            active ? .regular.tint(ClaudeTheme.accent).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 12)
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

    private var validationError: LocalizedStringResource? {
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
        .mobileSheetPresentation([.medium])
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
