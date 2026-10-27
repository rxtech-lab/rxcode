import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Agent confirmations and interactive views share one sheet presentation.
struct AgentPromptUIModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private enum Prompt: Identifiable {
        case confirmation(AgentConfirmation)
        case dialog(AgentUIDialog)

        var id: UUID {
            switch self {
            case .confirmation(let item): item.id
            case .dialog(let item): item.id
            }
        }
    }

    private var presentedPrompt: Prompt? {
        if (windowState.generalRoute == nil || windowState.generalRoute == .chat),
           let confirmation = appState.agentConfirmations(forSession: windowState.currentSessionId ?? windowState.newSessionKey).first,
           !confirmation.isMinimized {
            return .confirmation(confirmation)
        }
        return appState.agentPrompts.dialogs.first.map { .dialog($0) }
    }

    func body(content: Content) -> some View {
        let prompt = presentedPrompt
        content
            .background(WindowAttentionBadge(attention: appState.windowAttention(in: windowState)))
            .sheet(item: Binding(
                get: { presentedPrompt },
                set: { value in
                    guard value == nil, let prompt else { return }
                    switch prompt {
                    case .confirmation(let confirmation):
                        appState.setAgentConfirmationMinimized(id: confirmation.id, minimized: true)
                    case .dialog(let dialog):
                        appState.dismissAgentUIDialog(id: dialog.id)
                    }
                }
            )) { prompt in
                switch prompt {
                case .confirmation(let confirmation):
                    AgentConfirmationSheet(confirmation: confirmation)
                case .dialog(let dialog):
                    AgentUIDialogSheet(dialog: dialog) {
                        appState.dismissAgentUIDialog(id: dialog.id)
                    }
                }
            }
            .environment(\.openJSONUIDialog) { payload in
                guard let spec = payload.spec else { return }
                appState.openAgentUIView(
                    title: payload.title,
                    spec: spec,
                    sessionKey: windowState.currentSessionId ?? windowState.newSessionKey
                )
            }
    }
}

private struct AgentConfirmationSheet: View {
    @Environment(AppState.self) private var appState
    let confirmation: AgentConfirmation

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(confirmation.request.title)
                        .font(.title2.bold())
                    if let message = confirmation.request.message {
                        MarkdownContentView(text: message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Confirmation")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Minimize", systemImage: "minus") {
                        appState.setAgentConfirmationMinimized(id: confirmation.id, minimized: true)
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("Minimize to the banner above the input box")
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        Button(confirmation.request.cancelLabel) {
                            appState.resolveAgentConfirmation(id: confirmation.id, confirmed: false)
                        }
                        Button(confirmation.request.confirmLabel, role: confirmation.request.isDestructive ? .destructive : nil) {
                            appState.resolveAgentConfirmation(id: confirmation.id, confirmed: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity,
               minHeight: 320, idealHeight: 420, maxHeight: .infinity)
    }
}

/// Keeps a minimized confirmation accessible above its originating chat composer.
struct AgentConfirmationBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    var body: some View {
        if let confirmation = appState.agentConfirmations(forSession: windowState.currentSessionId ?? windowState.newSessionKey).first, confirmation.isMinimized {
            PendingActionBanner(
                icon: "questionmark.circle.fill",
                title: confirmation.request.title,
                actionTitle: String(localized: "Expand")
            ) {
                appState.setAgentConfirmationMinimized(id: confirmation.id, minimized: false)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("agent-confirmation-banner")
            .help("Expand the pending confirmation")
        }
    }
}

/// An agent's json-render view shown in its own sheet. Closing it keeps the
/// view in the thread's Views list in the inspector.
private struct AgentUIDialogSheet: View {
    let dialog: AgentUIDialog
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                JSONUIRenderer(spec: dialog.spec)
                    .padding(20)
            }
            .navigationTitle(dialog.title ?? String(localized: "Interactive View"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .help("Close. The view stays in this thread's Views list in the inspector.")
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 720, maxWidth: .infinity,
               minHeight: 480, idealHeight: 640, maxHeight: .infinity)
        // Esc closes the dialog the same way as Done. A no-op after Done.
        .onDisappear(perform: onDone)
    }
}

extension View {
    /// Attach the agent confirmation and UI dialog sheets.
    func agentPromptUI() -> some View { modifier(AgentPromptUIModifier()) }
}
