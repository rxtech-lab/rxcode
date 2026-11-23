import OSLog
import SwiftUI
import UIKit
import RxCodeCore
import RxCodeSync
import TipKit

/// Modal sheet for composing a new thread. Captures the prompt + config knobs
/// (branch, model, thinking level, permission mode), fires `requestNewSession` on submit, then
/// watches the session list for the freshly-created summary and dismisses,
/// handing the new session ID back to the caller so it can navigate.
private let newThreadLogger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "NewThread")

struct NewThreadSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID
    var preferredBranch: String? = nil
    /// Optional prompt to prefill the composer with (e.g. an autopilot setup
    /// request). The user can review/edit before sending.
    var initialText: String? = nil
    let onSessionCreated: (String) -> Void

    @State private var isSubmitting = false
    @State private var focusDismissalGeneration = 0
    @State private var awaitingFromSessionIDs: Set<String>?
    /// Re-requests a snapshot, then gives up, when the Mac never reports the
    /// new thread — so the send button can't spin forever.
    @State private var submitWatchdog: Task<Void, Never>?
    @State private var submitError: String?

    // Restore model choices on this device and seed the remaining settings from the Mac.
    @State private var planModeEnabled = false
    @State private var selectedProvider: AgentProvider?
    @State private var selectedModelID: String?
    @State private var selectedEffort: String?
    @State private var selectedPermissionMode: PermissionMode = .default
    @State private var didSeedPermissionMode = false
    @State private var hasPickedModelSettings = false

    private var projectName: String {
        state.projects.first(where: { $0.id == projectID })?.name ?? String(localized: "this project")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    NewThreadComposer(initialText: initialText ?? "", isSubmitting: isSubmitting, focusDismissalGeneration: focusDismissalGeneration, onSubmit: submit)
                    NewThreadConfigStrip(
                        projectID: projectID,
                        preferredBranch: preferredBranch,
                        selectedProvider: $selectedProvider,
                        selectedModelID: $selectedModelID,
                        selectedEffort: $selectedEffort,
                        selectedPermissionMode: $selectedPermissionMode,
                        planModeEnabled: $planModeEnabled,
                        onPickModelSettings: { hasPickedModelSettings = true },
                        onPresentSettings: { focusDismissalGeneration += 1 }
                    )
                    .environmentObject(state)
                    .disabled(isSubmitting)
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
        }
        .onChange(of: state.desktopSettings) { _, _ in
            seedConfigIfNeeded()
        }
        .onReceive(state.$sessions) { sessions in
            // @Published emits before assignment; inspect the emitted value.
            attemptJumpToNewSession(in: sessions)
        }
        .onDisappear {
            submitWatchdog?.cancel()
            submitWatchdog = nil
        }
        .alert(
            "Couldn't Start Thread",
            isPresented: Binding(
                get: { submitError != nil },
                set: { if !$0 { submitError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { submitError = nil }
        } message: {
            Text(submitError ?? "")
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

    private func seedConfigIfNeeded() {
        guard let settings = state.desktopSettings else { return }
        if !didSeedPermissionMode {
            didSeedPermissionMode = true
            selectedPermissionMode = settings.permissionMode
        }
        guard !hasPickedModelSettings else { return }
        if let saved = MobileModelPreferences.selection(in: settings) {
            selectedProvider = saved.provider
            selectedModelID = saved.model
            selectedEffort = saved.effort
        } else {
            selectedProvider = settings.selectedAgentProvider
            selectedModelID = settings.selectedModel
            selectedEffort = nil
        }
    }

    private func submit(_ body: String) {
        guard !body.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        awaitingFromSessionIDs = Set(
            state.sessions
                .filter { $0.projectId == projectID }
                .map { $0.id }
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        newThreadLogger.info("[NewThread] submit project=\(projectID.uuidString, privacy: .public) knownSessions=\(awaitingFromSessionIDs?.count ?? 0, privacy: .public) pendingBranchOps=\(state.inFlightBranchOps.count, privacy: .public) connection=\(String(describing: state.connectionState), privacy: .public)")
        Task {
            // Make sure the desktop has parked the picked branch's worktree
            // before the new session spawns; otherwise the two payloads race
            // and the thread lands on the project root instead of the
            // selected branch's worktree.
            await state.waitForPendingBranchOps()
            let levels = state.desktopSettings?.reasoningLevels(for: selectedProvider, model: selectedModelID) ?? []
            let effort = levels.first { $0.id == selectedEffort }?.id
            let sent = await state.requestNewSession(
                projectID: projectID,
                initialText: body,
                agentProvider: selectedProvider,
                model: selectedModelID,
                effort: effort,
                permissionMode: selectedPermissionMode,
                planMode: planModeEnabled
            )
            guard sent else {
                failSubmit(String(localized: "Your message couldn't be sent to your Mac. Check that RxCode is running on your Mac and try again."))
                return
            }
            startSubmitWatchdog()
        }
    }

    private func startSubmitWatchdog() {
        submitWatchdog?.cancel()
        submitWatchdog = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard awaitingFromSessionIDs != nil else { return }
            newThreadLogger.warning("[NewThread] no new thread after 8s; requesting snapshot connection=\(String(describing: state.connectionState), privacy: .public)")
            await state.requestSnapshot(reason: "new_thread_watchdog")
            do {
                try await Task.sleep(for: .seconds(22))
            } catch {
                return
            }
            guard awaitingFromSessionIDs != nil else { return }
            newThreadLogger.error("[NewThread] gave up waiting for the new thread after 30s connection=\(String(describing: state.connectionState), privacy: .public)")
            failSubmit(String(localized: "Your Mac didn't confirm the new thread. It may still appear in the thread list in a moment."))
        }
    }

    private func failSubmit(_ message: String) {
        submitWatchdog?.cancel()
        submitWatchdog = nil
        awaitingFromSessionIDs = nil
        isSubmitting = false
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        submitError = message
    }

    private func attemptJumpToNewSession(in sessions: [SessionSummary]) {
        guard let existing = awaitingFromSessionIDs else { return }
        let newest = sessions
            .filter { $0.projectId == projectID && !existing.contains($0.id) }
            .max(by: { $0.updatedAt < $1.updatedAt })
        guard let newest else { return }
        newThreadLogger.info("[NewThread] thread created session=\(newest.id, privacy: .public) project=\(projectID.uuidString, privacy: .public)")
        submitWatchdog?.cancel()
        submitWatchdog = nil
        awaitingFromSessionIDs = nil
        AnalyticsService.shared.log(.threadCreated, parameters: [
            "project_id": projectID.uuidString,
            "session_id": newest.id,
        ])
        onSessionCreated(newest.id)
        dismiss()
    }
}

/// Keeps high-frequency text edits out of the app-state observing sheet.
private struct NewThreadComposer: View {
    let initialText: String
    let isSubmitting: Bool
    let focusDismissalGeneration: Int
    let onSubmit: (String) -> Void
    @State private var text = ""
    @State private var didSeedText = false
    @State private var voiceSession = MobileVoiceInputSession()
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.95, green: 0.6, blue: 0.4),
                     Color(red: 0.85, green: 0.5, blue: 0.55),
                     Color(red: 0.65, green: 0.5, blue: 0.7)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    var body: some View {
        composer
            .mobileVoiceInput(session: voiceSession, text: $text)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: voiceSession.mode)
            .onChange(of: voiceSession.mode) { _, mode in
                if mode != .idle { isFocused = false }
            }
            .onChange(of: focusDismissalGeneration) { _, _ in isFocused = false }
            .task {
                guard !didSeedText else { return }
                didSeedText = true
                text = initialText
                // Let the sheet mount before asking the keyboard to attach.
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                guard focusDismissalGeneration == 0, !voiceSession.isPresented else { return }
                isFocused = true
                newThreadLogger.debug("PERFORMANCE: mobile new-thread composer ready")
            }
    }

    // MARK: - Composer (multiline input with embedded send)

    private var composer: some View {
        ZStack(alignment: .topLeading) {
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

                HStack {
                    MobileVoiceMicButton(text: $text, session: voiceSession)
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("new-thread-voice-input")
                    Spacer()
                    sendButton
                }
            }
            .opacity(voiceSession.isPresented ? 0 : 1)
            .allowsHitTesting(!voiceSession.isPresented)
            .accessibilityHidden(voiceSession.isPresented)
            if voiceSession.isPresented {
                VStack(alignment: .leading, spacing: 8) {
                    MobileVoiceCancelButton { text = voiceSession.discard() }
                    switch voiceSession.mode {
                    case .recording:
                        MobileVoiceRecordingContent(session: voiceSession)
                    case .review:
                        MobileVoiceReviewContent(session: voiceSession, canSend: !isSubmitting) {
                            text = voiceSession.draft
                            voiceSession.endReview()
                            isFocused = false
                            onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        } onEdit: {
                            text = voiceSession.draft
                            voiceSession.endReview()
                            isFocused = true
                        }
                    case .idle:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .transition(.blurReplace)
            }
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
            isFocused = false
            onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines))
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

}

// MARK: - Create Branch Sheet

struct CreateBranchSheet: View {
    /// How a new branch gets materialized on the desktop. Mirrors the desktop's
    /// `CreateBranchSheet.BranchMode`.
    enum BranchMode: String, CaseIterable, Identifiable {
        /// `git worktree add -b` — isolated checkout in a sibling directory.
        case worktree
        /// `git checkout -b` in the project root — mutates the main repo.
        case checkout

        var id: String { rawValue }

        var label: LocalizedStringResource {
            switch self {
            case .worktree: "New worktree"
            case .checkout: "Branch + checkout"
            }
        }

        var hint: LocalizedStringResource {
            switch self {
            case .worktree:
                "Creates an isolated worktree so this thread works without touching the main checkout."
            case .checkout:
                "Creates the branch and checks it out in the project root, changing the main checkout."
            }
        }
    }

    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let baseBranch: String?

    @State private var branchText: String = "rxcode/"
    @State private var mode: BranchMode = .worktree
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

                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(BranchMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isSubmitting)
                } header: {
                    Text("Mode")
                } footer: {
                    Text(mode.hint)
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
        let useWorktree = mode == .worktree
        Task {
            await state.createProjectBranch(projectID: projectID, branch: name, useWorktree: useWorktree)
            isSubmitting = false
            dismiss()
        }
    }
}
