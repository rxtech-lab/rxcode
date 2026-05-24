import AppKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI
import TipKit
import UniformTypeIdentifiers

// MARK: - Shared Chat UI Components

func effortDisplayName(_ effort: String) -> String {
    switch effort {
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "XHigh"
    case "max": return "Max"
    default: return effort.capitalized
    }
}

enum ChatToolbarControlsPlacement {
    case toolbar
    case composer
}

struct ChatToolbarControls: View {
    @Environment(AppState.self) var appState
    @Environment(WindowState.self) var windowState

    let placement: ChatToolbarControlsPlacement

    init(placement: ChatToolbarControlsPlacement = .toolbar) {
        self.placement = placement
    }

    var effectiveMode: PermissionMode { windowState.sessionPermissionMode ?? appState.permissionMode }
    var effectiveModel: String { appState.effectiveModelSelection(in: windowState).model }
    var effectiveProvider: AgentProvider { appState.effectiveModelSelection(in: windowState).provider }

    var body: some View {
        HStack(spacing: placement == .composer ? 8 : 4) {
            if placement == .composer {
                Spacer(minLength: 12)
            }

            Menu {
                Section("Permission Mode") {
                    ForEach(PermissionMode.allCases.filter { $0 != .plan }, id: \.self) { mode in
                        Button {
                            appState.setSessionPermissionMode(mode, in: windowState)
                        } label: {
                            Text(mode.displayName)
                            if effectiveMode == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                controlLabel(
                    title: effectiveMode.displayNameText,
                    icon: nil,
                    isAccent: placement == .composer,
                    isActive: false
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Permission mode: \(effectiveMode.displayNameText)")
            .accessibilityIdentifier("permission-mode-menu")

            Menu {
                Section("Model Picker") {
                    ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                        Section {
                            ForEach(section.models, id: \.key) { model in
                                Button {
                                    appState.setSessionModel(model.id, provider: model.provider, in: windowState)
                                } label: {
                                    let isSelected = effectiveProvider == model.provider && effectiveModel == model.id
                                    if let iconURL = section.iconURL {
                                        Label {
                                            Text(isSelected ? "\(model.displayName) ✓" : model.displayName)
                                        } icon: {
                                            ACPIconView(url: iconURL, size: 14)
                                        }
                                    } else {
                                        Text(isSelected ? "\(model.displayName) ✓" : model.displayName)
                                    }
                                }
                            }
                        } header: {
                            Text(section.title)
                        }
                    }
                }
            } label: {
                controlLabel(
                    title: "\(effectiveProvider == .codex ? "Codex · " : "")\(appState.modelDisplayLabel(effectiveModel, provider: effectiveProvider))",
                    icon: nil,
                    isAccent: false,
                    isActive: false
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model: \(effectiveProvider.displayNameText) · \(appState.modelDisplayLabel(effectiveModel, provider: effectiveProvider))")
            .accessibilityIdentifier("provider-model-menu")
            .popoverTip(RxCodeTips.AgentSelectionTip(), arrowEdge: .top)

            Menu {
                Section("Effort Picker") {
                    Button {
                        appState.setSessionEffort(nil, in: windowState)
                    } label: {
                        Text("Auto Effort")
                        if windowState.sessionEffort == nil { Image(systemName: "checkmark") }
                    }
                    Divider()
                    ForEach(AppState.availableEfforts, id: \.self) { effort in
                        Button {
                            appState.setSessionEffort(effort, in: windowState)
                        } label: {
                            Text(LocalizedStringKey(effortDisplayName(effort)))
                            if windowState.sessionEffort == effort { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                controlLabel(
                    title: windowState.sessionEffort.map { effortDisplayName($0) } ?? "Auto Effort",
                    icon: nil,
                    isAccent: false,
                    isActive: false
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Effort level: \(windowState.sessionEffort.map { effortDisplayName($0) } ?? "Auto Effort")")
            .accessibilityIdentifier("effort-menu")
        }
        .frame(maxWidth: placement == .composer ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder
    func controlLabel(title: String, icon: String?, isAccent: Bool, isActive: Bool) -> some View {
        switch placement {
        case .toolbar:
            ToolbarChipLabel(title: title, icon: icon, isActive: isActive)
        case .composer:
            ComposerControlLabel(title: title, icon: icon, isAccent: isAccent, isActive: isActive)
        }
    }
}

struct ToolbarChipLabel: View {
    let title: String
    var icon: String? = nil
    var isActive: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
        }
        .foregroundStyle(isActive ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isActive
                ? ClaudeTheme.accent.opacity(isHovered ? 0.18 : 0.12)
                : (isHovered ? ClaudeTheme.surfaceTertiary : ClaudeTheme.surfaceSecondary),
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(
                    isActive ? ClaudeTheme.accent.opacity(0.45) : ClaudeTheme.borderSubtle,
                    lineWidth: isActive ? 1 : 0.5
                )
        )
        .onHover { isHovered = $0 }
        .pointerCursorOnHover()
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

struct ComposerControlLabel: View {
    let title: String
    var icon: String? = nil
    let isAccent: Bool
    var isActive: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle((isAccent || isActive) ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            isActive
                ? ClaudeTheme.accent.opacity(isHovered ? 0.18 : 0.12)
                : (isHovered ? ClaudeTheme.surfaceSecondary.opacity(0.85) : Color.clear),
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(
                    isActive ? ClaudeTheme.accent.opacity(0.45) : Color.clear,
                    lineWidth: isActive ? 1 : 0
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .onHover { isHovered = $0 }
        .pointerCursorOnHover()
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

struct ChatDetailModifiers: ViewModifier {
    @Environment(AppState.self) var appState
    @Environment(WindowState.self) var windowState
    @Environment(ChatBridge.self) var chatBridge

    var presentedRequest: PermissionRequest? {
        guard let id = windowState.presentedPermissionId else { return nil }
        return windowState.pendingPermissions.first {
            $0.id == id && $0.sessionId == windowState.currentSessionId
        }
    }

    var presentedPermissionModalRequest: PermissionRequest? {
        guard let request = presentedRequest, request.toolName != "AskUserQuestion" else { return nil }
        return request
    }

    var questionSheetBinding: Binding<Bool> {
        Binding(
            get: { presentedRequest?.toolName == "AskUserQuestion" },
            set: { isPresented in
                if !isPresented, presentedRequest?.toolName == "AskUserQuestion" {
                    windowState.presentedPermissionId = nil
                }
            }
        )
    }

    var presentedPlan: PendingPlan? {
        guard let id = windowState.presentedPlanToolCallId else { return nil }
        return chatBridge.pendingPlans.first { $0.toolCallId == id }
    }

    var planSheetBinding: Binding<Bool> {
        Binding(
            get: { presentedPlan != nil },
            set: { isPresented in
                if !isPresented {
                    windowState.presentedPlanToolCallId = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowState.pendingPermissions.count)
            .overlay {
                if let request = presentedPermissionModalRequest {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                            .onTapGesture { windowState.presentedPermissionId = nil }
                        PermissionModal(request: request, onClose: { windowState.presentedPermissionId = nil })
                            .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
                            .shadow(color: ClaudeTheme.shadowColor, radius: 20)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowState.presentedPermissionId)
                }
            }
            .sheet(isPresented: questionSheetBinding) {
                if let request = presentedRequest, request.toolName == "AskUserQuestion" {
                    QuestionSheetView(
                        request: request,
                        remainingCount: max(0, windowState.pendingPermissions.count - 1),
                        onSubmit: { answers in
                            windowState.submitQuestionAnswersHandler?(request.id, answers)
                        },
                        onClose: {
                            // Just dismiss — keep the request in the queue so the user
                            // can re-open it from the banner later.
                            windowState.presentedPermissionId = nil
                        },
                        onSkipAll: {
                            windowState.skipQuestionHandler?(request.id)
                        }
                    )
                    .environment(appState)
                    .environment(windowState)
                }
            }
            .onChange(of: windowState.pendingPermissions.map(\.id)) { _, newIds in
                if let id = windowState.presentedPermissionId, !newIds.contains(id) {
                    windowState.presentedPermissionId = nil
                }
            }
            .sheet(isPresented: planSheetBinding) {
                if let plan = presentedPlan {
                    PlanSheetView(
                        plan: plan,
                        remainingCount: max(0, chatBridge.pendingPlans.filter { !$0.isDecided }.count - 1),
                        onSubmit: { toolCallId, action in
                            windowState.planDecisionHandler?(toolCallId, action)
                            // Decision recorded — close the sheet. The chip in chat
                            // will reflect the new status once the result lands.
                            windowState.presentedPlanToolCallId = nil
                        },
                        onClose: {
                            // Just dismiss — the plan stays in the queue so the user
                            // can re-open it from the banner or inline chip later.
                            windowState.presentedPlanToolCallId = nil
                        }
                    )
                    .environment(appState)
                    .environment(windowState)
                    .environment(chatBridge)
                }
            }
            .onChange(of: chatBridge.pendingPlans.map(\.toolCallId)) { _, newIds in
                if let id = windowState.presentedPlanToolCallId, !newIds.contains(id) {
                    windowState.presentedPlanToolCallId = nil
                }
            }
            .sheet(isPresented: Bindable(windowState).showModelPicker) {
                ModelPickerSheet()
                    .environment(appState)
                    .environment(windowState)
            }
            .sheet(isPresented: Bindable(windowState).showEffortPicker) {
                EffortPickerSheet()
                    .environment(appState)
                    .environment(windowState)
            }
            .sheet(item: Bindable(windowState).interactiveTerminal) { terminal in
                InteractiveTerminalPopup(state: terminal)
            }
    }
}
