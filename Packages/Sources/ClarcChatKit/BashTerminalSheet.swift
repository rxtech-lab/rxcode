import SwiftUI
import ClarcCore

/// Terminal-styled sheet that surfaces the output of a completed `Bash` tool call.
/// Mirrors the look of the interactive terminal popup (dark background, monospaced
/// text, success/error chip in the header) but is read-only — we only have the
/// captured stdout/stderr to show.
struct BashTerminalSheet: View {
    let toolCall: ToolCall

    @Environment(\.dismiss) private var dismiss

    private var command: String {
        toolCall.input["command"]?.stringValue ?? ""
    }

    private var description: String? {
        toolCall.input["description"]?.stringValue
    }

    private var resultText: String {
        toolCall.result ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()
            terminalBody
        }
        .frame(minWidth: 800, idealWidth: 900, minHeight: 500, idealHeight: 600)
        .background(ClaudeTheme.surfaceElevated)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(ClaudeTheme.accent)
            Text(description ?? String(localized: "Bash", bundle: .module))
                .font(.system(size: ClaudeTheme.size(13), weight: .medium, design: .monospaced))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: toolCall.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(toolCall.isError ? ClaudeTheme.statusError : ClaudeTheme.statusSuccess)
                Text(toolCall.isError ? "error" : "ok")
                    .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            Button {
                copyResult()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Copy output", bundle: .module))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Body

    @ViewBuilder
    private var terminalBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !command.isEmpty {
                    promptLine
                }
                if !resultText.isEmpty {
                    Text(resultText)
                        .font(.system(size: ClaudeTheme.messageSize(12), design: .monospaced))
                        .foregroundStyle(toolCall.isError ? ClaudeTheme.statusError : ClaudeTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("(no output)", bundle: .module)
                        .font(.system(size: ClaudeTheme.messageSize(12), design: .monospaced))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ClaudeTheme.codeBackground)
    }

    @ViewBuilder
    private var promptLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("$")
                .font(.system(size: ClaudeTheme.messageSize(12), weight: .bold, design: .monospaced))
                .foregroundStyle(ClaudeTheme.accent)
            Text(command)
                .font(.system(size: ClaudeTheme.messageSize(12), design: .monospaced))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resultText, forType: .string)
    }
}
