import SwiftUI
import RxCodeCore

struct ToolCallDetailSheet: View {
    let toolCall: ToolCall
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: ClaudeTheme.messageSize(16), weight: .medium))
                    .foregroundStyle(ClaudeTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: ClaudeTheme.messageSize(15), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    Text(statusText)
                        .font(.system(size: ClaudeTheme.messageSize(12)))
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: ClaudeTheme.messageSize(12), weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(16)

            ClaudeThemeDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !toolCall.detectedShellFileChanges.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Detected File Changes")
                                .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                                .foregroundStyle(ClaudeTheme.textSecondary)
                            ShellDetectedChangesView(changes: toolCall.detectedShellFileChanges)
                        }
                    }
                    JSONCodeBlock(title: "Call Params", code: Self.prettyJSONString(.object(toolCall.displayInput)))
                    JSONCodeBlock(title: "Result", code: Self.prettyResultString(toolCall.result))
                }
                .padding(16)
            }
        }
        .toolCallDetailFrame()
        .background(ClaudeTheme.surfacePrimary)
    }

    private var toolNameLower: String { toolCall.name.lowercased() }
    private var isMCP: Bool { ToolCategory(toolName: toolCall.name) == .mcp }

    private var iconName: String {
        if isMCP { return "puzzlepiece.extension" }
        switch toolNameLower {
        case "agent":        return "cpu"
        case "read":         return "doc.text"
        case "grep", "glob": return "magnifyingglass"
        case "write":        return "square.and.pencil"
        case "edit",
             "multiedit",
             "multi_edit":   return "pencil"
        case "bash":         return "terminal"
        case "notebookedit": return "book.and.wrench"
        case "skill":        return "sparkles"
        default:             return ToolCategory(toolName: toolNameLower).sfSymbol
        }
    }

    private var displayName: String {
        if isMCP {
            if toolNameLower == "mcptoolcall" {
                return "MCP tool call"
            }
            return toolCall.name
                .replacingOccurrences(of: "mcp__", with: "")
                .replacingOccurrences(of: "__", with: " / ")
        }
        return toolCall.name
    }

    private var statusText: String {
        if toolCall.isError, !(toolCall.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Failed"
        }
        if toolCall.result != nil {
            return "Completed"
        }
        return "Running"
    }

    private var statusColor: Color {
        statusText == "Failed" ? ClaudeTheme.statusError : ClaudeTheme.textTertiary
    }

    private static func prettyResultString(_ result: String?) -> String {
        guard let result else { return "null" }
        if result.isEmpty { return "\"\"" }
        if let data = result.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: pretty, encoding: .utf8) {
            return string
        }
        return prettyJSONString(.string(result))
    }

    private static func prettyJSONString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return value.description
        }
        return string
    }
}

extension View {
    @ViewBuilder
    func toolCallDetailSheetPresentation() -> some View {
#if os(iOS)
        self
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
#else
        self
#endif
    }

    @ViewBuilder
    func toolCallDetailFrame() -> some View {
#if os(macOS)
        self.frame(minWidth: 640, minHeight: 460)
#else
        self.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#endif
    }
}

private struct JSONCodeBlock: View {
    let title: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer()
                Text("json")
                    .font(.system(size: ClaudeTheme.messageSize(11), weight: .medium, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ClaudeTheme.codeHeaderBackground)

            ScrollView([.horizontal, .vertical]) {
                Text(SyntaxHighlighter.highlight(code, language: "json", fontSize: ClaudeTheme.messageSize(12)))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .background(ClaudeTheme.codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
    }
}
