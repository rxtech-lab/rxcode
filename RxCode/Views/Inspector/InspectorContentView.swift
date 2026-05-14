import SwiftUI
import RxCodeCore

// MARK: - InspectorContentView

/// Inspector-mode body for the right sidebar: Terminal + Memo, switched by
/// `windowState.inspectorTab`. State for the terminal process and reset/clear
/// triggers is owned by the parent (`RightInspectorPanel`) so header action
/// buttons can drive them.
struct InspectorContentView: View {
    @Environment(WindowState.self) private var windowState

    @Binding var inspectorProcess: TerminalProcess
    let terminalResetID: UUID
    let memoClearID: UUID?
    let terminalFocusID: UUID?
    let memoFocusID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            EmbeddedTerminalView(
                executable: "/bin/zsh",
                arguments: ["-il"],
                currentDirectory: windowState.selectedProject?.path,
                process: inspectorProcess,
                focusTrigger: terminalFocusID
            )
            .id(terminalResetID)
            .padding(8)
            .background(ClaudeTheme.codeBackground)
            .frame(maxHeight: windowState.inspectorTab == .terminal ? .infinity : 0)
            .clipped()

            InspectorMemoPanel(projectId: windowState.selectedProject?.id,
                               clearTrigger: memoClearID,
                               focusTrigger: memoFocusID)
                .frame(maxHeight: windowState.inspectorTab == .memo ? .infinity : 0)
                .clipped()

            RunOutputInspectorView()
                .frame(maxHeight: windowState.inspectorTab == .run ? .infinity : 0)
                .clipped()
        }
    }
}

// MARK: - InspectorIconButton

struct InspectorIconButton: View {
    let help: String
    let systemImage: String
    let action: () -> Void

    init(help: String, systemImage: String = "arrow.counterclockwise", action: @escaping () -> Void) {
        self.help = help
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
