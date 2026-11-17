import SwiftUI
import RxCodeCore

private enum OpenJSONUIDialogKey: EnvironmentKey {
    static var defaultValue: ((JSONUITool.Payload) -> Void)? { nil }
}

extension EnvironmentValues {
    /// Opens a `show_ui` view that asked for `presentation: "dialog"`. Hosts that present
    /// dialogs set it; without it, the chat draws those views inline.
    public var openJSONUIDialog: ((JSONUITool.Payload) -> Void)? {
        get { self[OpenJSONUIDialogKey.self] }
        set { self[OpenJSONUIDialogKey.self] = newValue }
    }
}

/// The body of a dialog `show_ui` card: a short note and a button reopening the view, in
/// place of the view itself.
struct JSONUIDialogOpenRow: View {
    let payload: JSONUITool.Payload
    let open: (JSONUITool.Payload) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Shown in a dialog.", bundle: .module)
                .font(.callout)
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer(minLength: 8)
            Button {
                open(payload)
            } label: {
                Label {
                    Text("Open", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
            }
            .controlSize(.small)
        }
    }
}
