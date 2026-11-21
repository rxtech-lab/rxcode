import OSLog
import SwiftUI
import UIKit
import RxCodeCore
import RxCodeSync
import TipKit

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
    var onPresentSettings: () -> Void = {}
    @State private var showingCreateBranch = false
    @State private var modelPicker: NewThreadModelPickerSnapshot?
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

            LazyVGrid(columns: columns, spacing: 12) {
                branchMenu
                modelMenu
                permissionMenu
                planToggleChip
            }
        }
        .sheet(isPresented: $showingCreateBranch) {
            CreateBranchSheet(
                projectID: projectID,
                baseBranch: state.projectBranches[projectID]
            )
            .environmentObject(state)
        }
        .sheet(item: $modelPicker) { snapshot in
            NewThreadModelPicker(snapshot: snapshot) { model in
                applyModel(model)
            }
            .mobileSheetPresentation([.large])
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
        Button {
            MobileHaptics.buttonTap()
            onPresentSettings()
            modelPicker = NewThreadModelPickerSnapshot(
                sections: modelSections,
                selectedProvider: selectedProvider,
                selectedModelID: selectedModelID
            )
        } label: {
            chipLabel(icon: "cpu", title: selectedModelLabel)
        }
        .accessibilityIdentifier("new-thread-model-picker")
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
        .background {
            if active {
                MobileCard.shape.fill(ClaudeTheme.accent)
            } else {
                MobileCardSurface()
            }
        }
        .contentShape(MobileCard.shape)
    }
}
