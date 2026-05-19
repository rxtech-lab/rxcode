import SwiftUI
import RxCodeCore

struct ToolResultView: View {
    let toolCall: ToolCall
    var isMessageStreaming: Bool = false
    @State private var isExpanded: Bool
    @State private var isDiffExpanded = false
    @State private var showBashSheet = false
    @Environment(WindowState.self) private var windowState

    /// Lowercased tool name (avoids repeated lowercased() calls)
    private let toolNameLower: String

    init(toolCall: ToolCall, isMessageStreaming: Bool = false) {
        self.toolCall = toolCall
        self.isMessageStreaming = isMessageStreaming
        let lower = toolCall.name.lowercased()
        self.toolNameLower = lower
        let isTransient = ToolCategory(toolName: lower).isTransient
        // Edit tool is expanded by default; transient tools are expanded only while running (until result arrives)
        self._isExpanded = State(initialValue:
            lower == "edit" || lower == "multiedit"
            || (isTransient && isMessageStreaming && toolCall.result == nil)
        )
    }

    /// Description input for the Agent tool
    private var agentDescription: String? {
        guard toolNameLower == "agent" else { return nil }
        return toolCall.input["description"]?.stringValue
    }

    /// Agent header title: "type: description" format
    private var agentDisplayTitle: String {
        let agentType = toolCall.input["subagent_type"]?.stringValue
        let desc = toolCall.input["description"]?.stringValue
        if let type = agentType, let desc {
            return "\(type): \(desc)"
        }
        return desc ?? agentType ?? "Agent"
    }

    /// Skill name for the Skill tool
    private var skillName: String? {
        guard toolNameLower == "skill" else { return nil }
        return toolCall.input["skill"]?.stringValue
    }

    var body: some View {
        Group {
            if isCardTool {
                cardBody
                    .bubbleStyle(toolCall.isError ? .toolError : .tool)
                    .padding(.vertical, 6)
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .move(edge: .top))
                            .combined(with: .scale(scale: 0.96, anchor: .top)),
                        removal: .opacity
                    ))
            } else {
                minimalBody
            }
        }
        .onChange(of: toolCall.result) { _, newResult in
            guard ToolCategory(toolName: toolNameLower).isTransient, newResult != nil else { return }
            isExpanded = false
        }
    }

    /// Edit/MultiEdit get the full framed card with diff view.
    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header + Input summary (both clickable)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: sfSymbol)
                            .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                            .foregroundStyle(iconColor)
                            .frame(width: 16, height: 16)

                        if toolNameLower == "agent" {
                            Text(agentDisplayTitle)
                                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                                .foregroundStyle(ClaudeTheme.textPrimary)
                        } else if let skillName = skillName {
                            Text(skillName)
                                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                                .foregroundStyle(ClaudeTheme.textPrimary)
                        } else {
                            Text(toolCall.name)
                                .font(.system(size: ClaudeTheme.messageSize(13), weight: .medium))
                                .foregroundStyle(ClaudeTheme.textPrimary)
                        }

                        Spacer()

                        Group {
                            if toolCall.isError {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(ClaudeTheme.statusError)
                                    .font(.caption)
                                    .accessibilityLabel("Error occurred")
                            } else if toolCall.result != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ClaudeTheme.statusSuccess)
                                    .font(.caption)
                                    .accessibilityLabel("Completed")
                            } else if isMessageStreaming {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityLabel("Running")
                            } else {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(ClaudeTheme.textTertiary)
                                    .font(.caption)
                                    .accessibilityLabel("Interrupted")
                            }
                        }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .id(statusIconID)

                        if toolCall.result != nil || hasExpandableContent {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(ClaudeTheme.textTertiary)
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: statusIconID)

                    inputSummaryView(maximumNumberOfLines: isExpanded ? nil : 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                Group {
                    if isEditTool, let oldStr = toolCall.input["old_string"]?.stringValue,
                       let newStr = toolCall.input["new_string"]?.stringValue {
                        VStack(alignment: .leading, spacing: 6) {
                            ClaudeThemeDivider()
                            editDiffView(oldString: oldStr, newString: newStr)
                        }
                    } else if isEditTool, !toolCall.fileChangeDiffs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ClaudeThemeDivider()
                            fileChangeDiffsView(toolCall.fileChangeDiffs)
                        }
                    } else if let result = toolCall.result, !result.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ClaudeThemeDivider()

                            ScrollView {
                                ChatTextContentView(
                                    result,
                                    size: ClaudeTheme.messageSize(12),
                                    design: .monospaced,
                                    color: toolCall.isError ? ClaudeTheme.statusError : ClaudeTheme.textPrimary
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    /// Stable identifier for the current status icon — used to animate transitions
    /// between progress / checkmark / error states.
    private var statusIconID: Int {
        if toolCall.isError { return 1 }
        if toolCall.result != nil { return 2 }
        if isMessageStreaming { return 3 }
        return 4
    }

    /// Read / Bash / Grep / Write / Agent / Skill / MCP / etc. — single muted row, no card.
    @ViewBuilder
    private var minimalBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isBashTool, toolCall.result != nil {
                    showBashSheet = true
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if toolCall.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: ClaudeTheme.messageSize(11)))
                            .foregroundStyle(ClaudeTheme.statusError)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: sfSymbol)
                            .font(.system(size: ClaudeTheme.messageSize(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .frame(width: 14, height: 14)
                    }

                    inputSummaryView(maximumNumberOfLines: 1)

                    if toolCall.result == nil && isMessageStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Running")
                    }
                }
                .font(.system(size: ClaudeTheme.messageSize(12)))
                .foregroundStyle(toolCall.isError ? ClaudeTheme.statusError : ClaudeTheme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !isBashTool, let result = toolCall.result, !result.isEmpty {
                ScrollView {
                    ChatTextContentView(
                        result,
                        size: ClaudeTheme.messageSize(12),
                        design: .monospaced,
                        color: toolCall.isError ? ClaudeTheme.statusError : ClaudeTheme.textSecondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(.leading, 20)
            }
        }
        .sheet(isPresented: $showBashSheet) {
            BashTerminalSheet(toolCall: toolCall)
        }
    }

    private var isBashTool: Bool {
        toolNameLower == "bash"
    }

    private var isCardTool: Bool {
        isEditTool
    }

    // MARK: - Edit Diff

    private var isEditTool: Bool {
        toolNameLower == "edit" || toolNameLower == "multiedit" || toolNameLower == "multi_edit"
    }

    private var hasExpandableContent: Bool {
        isEditTool && (
            (toolCall.input["old_string"]?.stringValue != nil
                && toolCall.input["new_string"]?.stringValue != nil)
            || !toolCall.fileChangeDiffs.isEmpty
        )
    }

    private func editHunksFromToolInput() -> [PreviewFile.EditHunk] {
        guard isEditTool else { return [] }
        return toolCall.fileEditHunks
    }

    private func editDiffView(oldString: String, newString: String) -> some View {
        let (trimmedOld, trimmedNew) = stripCommonIndent(
            old: oldString.components(separatedBy: .newlines),
            new: newString.components(separatedBy: .newlines)
        )
        let removedLines = trimmedOld.map { ("-", $0, false) }
        let addedLines = trimmedNew.map { ("+", $0, true) }
        let allLines = removedLines + addedLines

        let collapseThreshold = 12
        let needsToggle = allLines.count > collapseThreshold
        let visibleLines = needsToggle && !isDiffExpanded
            ? Array(allLines.prefix(collapseThreshold))
            : allLines

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { idx, item in
                let (prefix, text, isAdded) = item
                ChatTextContentView(
                    prefix + " " + text,
                    size: ClaudeTheme.messageSize(12),
                    design: .monospaced,
                    color: isAdded ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background((isAdded ? ClaudeTheme.statusSuccess : ClaudeTheme.statusError).opacity(0.06))
                    .transition(.asymmetric(
                        insertion: .move(edge: isAdded ? .leading : .trailing)
                            .combined(with: .opacity),
                        removal: .opacity
                    ))
                    .animation(
                        .easeOut(duration: 0.28).delay(Double(idx) * 0.015),
                        value: visibleLines.count
                    )
            }

            if needsToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isDiffExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if isDiffExpanded {
                                Text("Show less", bundle: .module)
                            } else {
                                Text("Show more", bundle: .module)
                            }
                        }
                        .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                        Image(systemName: isDiffExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                    }
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .fill(ClaudeTheme.surfacePrimary.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .textSelection(.enabled)
    }

    private func fileChangeDiffsView(_ changes: [ToolCall.FileChangeDiff]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 4) {
                    if changes.count > 1 {
                        Text(URL(fileURLWithPath: change.path).lastPathComponent)
                            .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(1)
                    }
                    rawUnifiedDiffView(change.diff)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func rawUnifiedDiffView(_ diff: String) -> some View {
        let lines = diff.components(separatedBy: .newlines)
        let collapseThreshold = 18
        let needsToggle = lines.count > collapseThreshold
        let visibleLines = needsToggle && !isDiffExpanded
            ? Array(lines.prefix(collapseThreshold))
            : lines

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                ChatTextContentView(
                    line.isEmpty ? " " : line,
                    size: ClaudeTheme.messageSize(12),
                    design: .monospaced,
                    color: diffLineColor(line)
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(diffLineBackground(line))
            }

            if needsToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isDiffExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(isDiffExpanded ? "Show less" : "Show more", bundle: .module)
                            .font(.system(size: ClaudeTheme.messageSize(12), weight: .medium))
                        Image(systemName: isDiffExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: ClaudeTheme.messageSize(10), weight: .medium))
                    }
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .fill(ClaudeTheme.surfacePrimary.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return ClaudeTheme.statusSuccess }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return ClaudeTheme.statusError }
        if line.hasPrefix("@@") { return ClaudeTheme.accent }
        return ClaudeTheme.textPrimary
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return ClaudeTheme.statusSuccess.opacity(0.06) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return ClaudeTheme.statusError.opacity(0.06) }
        if line.hasPrefix("@@") { return ClaudeTheme.accent.opacity(0.08) }
        return Color.clear
    }

    // MARK: - Helpers

    private var sfSymbol: String {
        switch toolNameLower {
        case "agent":      return "cpu"
        case "read":       return "doc.text"
        case "grep":       return "magnifyingglass"
        case "glob":       return "magnifyingglass"
        case "write":      return "square.and.pencil"
        case "multiedit",
             "multi_edit": return "pencil"
        case "bash":       return "terminal"
        case "notebookedit": return "book.and.wrench"
        case InteractiveTerminalState.toolName: return "apple.terminal"
        default:           return ToolCategory(toolName: toolNameLower).sfSymbol
        }
    }

    private var iconColor: Color {
        switch toolNameLower {
        case "agent", "bash",
             InteractiveTerminalState.toolName: return ClaudeTheme.accent
        case "edit", "multiedit", "multi_edit",
             "write", "notebookedit": return ClaudeTheme.statusWarning
        case "read", "grep", "glob": return ClaudeTheme.textSecondary
        default:
            switch ToolCategory(toolName: toolNameLower) {
            case .execution: return ClaudeTheme.accent
            case .fileModification: return ClaudeTheme.statusWarning
            case .readOnly: return ClaudeTheme.textSecondary
            case .mcp, .unknown: return ClaudeTheme.textTertiary
            }
        }
    }

    @ViewBuilder
    private func fileActionLink(label: String, color: Color = ClaudeTheme.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: ClaudeTheme.messageSize(12)))
                .foregroundStyle(color)
                .underline()
        }
        .buttonStyle(.plain)
        .pointerCursorOnHover()
    }

    @ViewBuilder
    private func inputSummaryView(maximumNumberOfLines: Int? = nil) -> some View {
        if isEditTool || toolNameLower == "write",
           let filePath = toolCall.editedFilePath {
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            HStack(spacing: 0) {
                Text("\(toolDescriptionPrefix) — ")
                    .font(.system(size: ClaudeTheme.messageSize(12)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                fileActionLink(label: fileName, color: ClaudeTheme.accent) {
                    windowState.inspectorFile = PreviewFile(path: filePath, name: fileName)
                }
                if isEditTool, toolCall.result != nil {
                    let hunks = editHunksFromToolInput()
                    if !hunks.isEmpty {
                        HStack(spacing: 0) {
                            Text(" · ")
                                .font(.system(size: ClaudeTheme.messageSize(12)))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                            fileActionLink(label: "diff") {
                                windowState.diffFile = PreviewFile(
                                    path: filePath,
                                    name: fileName,
                                    editHunks: hunks
                                )
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                    }
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.25), value: toolCall.result != nil)
        } else {
            ChatTextContentView(
                inputSummary,
                size: ClaudeTheme.messageSize(12),
                color: ClaudeTheme.textSecondary,
                maximumNumberOfLines: maximumNumberOfLines
            )
        }
    }

    private var inputSummary: String {
        if toolNameLower == "agent" {
            if let desc = toolCall.input["description"]?.stringValue {
                return desc
            }
            if let prompt = toolCall.input["prompt"]?.stringValue {
                let truncated = prompt.count > 60 ? String(prompt.prefix(60)) + "..." : prompt
                return truncated
            }
            return toolDescriptionPrefix
        }

        if toolNameLower == "skill" {
            if let name = toolCall.input["skill"]?.stringValue {
                return "\(toolDescriptionPrefix) — \(name)"
            }
            return toolDescriptionPrefix
        }

        if let filePath = toolCall.input["file_path"]?.stringValue {
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            return "\(toolDescriptionPrefix) — \(fileName)"
        }
        if let filePath = toolCall.editedFilePath {
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            return "\(toolDescriptionPrefix) — \(fileName)"
        }
        if let command = toolCall.input["command"]?.stringValue {
            return "\(toolDescriptionPrefix) — \(command.count > 50 ? String(command.prefix(50)) + "..." : command)"
        }
        if let pattern = toolCall.input["pattern"]?.stringValue {
            return "\(toolDescriptionPrefix) — '\(pattern)'"
        }
        if let path = toolCall.input["path"]?.stringValue {
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return "\(toolDescriptionPrefix) — \(fileName)"
        }

        return toolDescriptionPrefix
    }

    private var toolDescriptionPrefix: String {
        switch toolNameLower {
        case "read": "Read file"
        case "edit": "Edit file"
        case "write": "Create new file"
        case "bash": "Run command"
        case "glob": "Find files"
        case "grep": "Search in code"
        case "multiedit": "Edit multiple locations"
        case "notebookedit": "Edit notebook"
        case "agent": "Subagent"
        case "skill": "Skill"
        case InteractiveTerminalState.toolName: "Interactive terminal"
        default: toolCall.name
        }
    }
}
