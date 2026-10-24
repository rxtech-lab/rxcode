import RxCodeCore
import SwiftUI

/// Runs authentication directly on a PTY instead of handing a script to
/// an external app whose process and completion RxCode cannot observe.
struct ACPTerminalSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: InteractiveTerminalState
    let onSuccess: () -> Void

    @State private var process = TerminalProcess()
    @State private var exitCode: Int32?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.title)
                    .font(.headline)
                Spacer()
                Button(exitCode == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            EmbeddedTerminalView(
                executable: state.executable,
                arguments: state.arguments,
                environment: state.environment,
                currentDirectory: state.currentDirectory,
                onProcessTerminated: { code in
                    Task { @MainActor in
                        guard !process.terminated else { return }
                        exitCode = code
                        if code == 0 { onSuccess() }
                    }
                },
                process: process
            )
            .padding(8)
            .background(ClaudeTheme.codeBackground)
            .overlay(alignment: .bottom) {
                if let exitCode, exitCode != 0 {
                    Text("Authentication command ended with exit code \(exitCode). Close this sheet and try again.")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
        }
        .frame(width: 800, height: 560)
        .interactiveDismissDisabled(exitCode == nil)
        .onDisappear { process.terminate() }
    }
}
