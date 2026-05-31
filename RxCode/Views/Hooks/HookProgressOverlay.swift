import RxCodeCore
import SwiftUI

/// Hook-driven UI presented at the window root: a loading dialog whose status
/// the running hook controls, a single-choice picker, and a confirmation alert.
/// All three are keyed off `AppState` because hook dispatch (e.g. project-add)
/// is app-level, not scoped to a single window.
struct HookUIModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .overlay {
                if let status = appState.hookProgressStatus {
                    HookProgressDialog(status: status)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.hookProgressStatus == nil)
            .sheet(item: Bindable(appState).hookChoiceRequest, onDismiss: {
                // Resume with nil if the sheet was dismissed without a pick.
                appState.resolveHookChoice(nil)
            }) { request in
                HookChoiceSheet(request: request)
                    .environment(appState)
            }
            .alert(
                appState.hookConfirmRequest?.title ?? "",
                isPresented: Binding(
                    get: { appState.hookConfirmRequest != nil },
                    set: { if !$0 { appState.resolveHookConfirm(false) } }
                ),
                presenting: appState.hookConfirmRequest
            ) { _ in
                Button("Overwrite", role: .destructive) { appState.resolveHookConfirm(true) }
                Button("Cancel", role: .cancel) { appState.resolveHookConfirm(false) }
            } message: { request in
                if let detail = request.detail {
                    Text(detail)
                }
            }
    }
}

extension View {
    /// Attach the hook-driven loading dialog / picker / confirm UI.
    func hookUI() -> some View { modifier(HookUIModifier()) }
}

/// The loading card the running hook drives via `HookController.beginProgress`.
private struct HookProgressDialog: View {
    let status: LocalizedStringKey

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(minWidth: 220)
            .background(ClaudeTheme.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClaudeTheme.border, lineWidth: 1))
            .shadow(radius: 24)
        }
    }
}

/// Single-choice picker presented by `HookController.requestChoice`.
private struct HookChoiceSheet: View {
    @Environment(AppState.self) private var appState
    let request: HookChoiceRequest

    @State private var selectedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.title).font(.headline)

            Picker("", selection: $selectedId) {
                ForEach(request.choices) { choice in
                    Text(choice.label).tag(Optional(choice.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { appState.resolveHookChoice(nil) }
                Button("Choose") { appState.resolveHookChoice(selectedId) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedId == nil)
            }
        }
        .padding(20)
        .frame(width: 420, height: 300)
        .onAppear { selectedId = request.choices.first?.id }
    }
}
