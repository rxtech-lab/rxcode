#if os(macOS)
import SwiftUI
import RxCodeCore

/// Popover that turns a natural-language requirement into a Swift `checkShowMenu`
/// condition using the default model, then compiles the result before handing it
/// back. On a clean compile it closes and reports the script as compiled; if the
/// generated script doesn't build, it stays open, shows the diagnostics, and still
/// drops the script into the editor (marked not-compiled) so the user can fix it.
struct SwiftConditionGeneratePopover: View {
    @Environment(AppState.self) private var appState

    let projectId: UUID?
    @Binding var isPresented: Bool
    /// `(script, compiled)` — compiled is true only when the generated script built.
    var onResult: (String, Bool) -> Void

    @State private var requirement = ""
    @State private var isGenerating = false
    @State private var diagnostics: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generate condition with AI")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
            Text("Describe when this menu item should appear. The default model writes the Swift condition and it's compiled before use.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $requirement)
                .font(.system(size: ClaudeTheme.size(12)))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor)))
                .disabled(isGenerating)

            if let diagnostics {
                ScrollView {
                    Text(verbatim: diagnostics)
                        .font(.system(size: ClaudeTheme.size(10), design: .monospaced))
                        .foregroundStyle(ClaudeTheme.statusError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .disabled(isGenerating)
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Generate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func generate() async {
        isGenerating = true
        diagnostics = nil
        defer { isGenerating = false }

        let project = appState.projects.first { $0.id == projectId }
        guard let script = await appState.generateMenuConditionScript(requirement: requirement, project: project),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagnostics = "The model didn't return a script. Try rephrasing your requirement."
            return
        }

        let result = await appState.compileMenuConditionScript(script)
        if result.success {
            onResult(script, true)
            isPresented = false
        } else {
            // Surface the script (uncompiled) so the user can fix it, and show why.
            onResult(script, false)
            diagnostics = result.diagnostics.isEmpty
                ? "The generated script didn't compile. Edit it and compile again."
                : result.diagnostics
        }
    }
}
#endif
