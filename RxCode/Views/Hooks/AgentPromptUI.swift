import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Agent-driven prompts presented at the window root: `ide__show_confirmation`
/// as a native alert and `ide__show_ui` views opened with
/// `presentation: "dialog"` as a sheet. Both queue on `AppState`, so each shows
/// the oldest pending item and the next one appears when it is settled. Also
/// lets the chat's dialog cards reopen their view.
struct AgentPromptUIModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    func body(content: Content) -> some View {
        let confirmation = appState.agentPrompts.confirmations.first
        content
            .alert(
                confirmation?.request.title ?? "",
                isPresented: Binding(
                    get: { confirmation != nil },
                    set: { if !$0, let confirmation { appState.resolveAgentConfirmation(id: confirmation.id, confirmed: false) } }
                ),
                presenting: confirmation
            ) { confirmation in
                Button(confirmation.request.confirmLabel, role: confirmation.request.isDestructive ? .destructive : nil) {
                    appState.resolveAgentConfirmation(id: confirmation.id, confirmed: true)
                }
                .keyboardShortcut(.defaultAction)
                Button(confirmation.request.cancelLabel, role: .cancel) {
                    appState.resolveAgentConfirmation(id: confirmation.id, confirmed: false)
                }
            } message: { confirmation in
                if let message = confirmation.request.message {
                    Text(message)
                }
            }
            // The sheet removes its own dialog, so the setter has nothing to do.
            .sheet(item: Binding(
                get: { appState.agentPrompts.dialogs.first },
                set: { _ in }
            )) { dialog in
                AgentUIDialogSheet(dialog: dialog) {
                    appState.dismissAgentUIDialog(id: dialog.id)
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
    /// Attach the agent confirmation alert and UI dialog sheet.
    func agentPromptUI() -> some View { modifier(AgentPromptUIModifier()) }
}
