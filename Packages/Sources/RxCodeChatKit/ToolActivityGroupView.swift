import SwiftUI
import RxCodeCore

/// Compact tool activity shared by mobile transcripts and account Agent Chat.
/// Shows what the agent did as a collapsible step timeline; tool results stay hidden.
public struct ToolActivityGroupView: View {
    let tools: [ToolCall]
    let isStreaming: Bool
    @State private var isExpanded = false
    @State private var showingActivitySheet = false
    @State private var selectedID: String?

    /// Interactive json-render views drawn inline above the group instead of folded into it.
    private let views: [ToolCall]

    public init(tools: [ToolCall], isStreaming: Bool = false) {
        self.tools = tools.filter { !JSONUITool.matches($0) }
        self.views = tools.filter { JSONUITool.matches($0) }
        self.isStreaming = isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(views) { view in
                JSONUIToolCard(toolCall: view, isStreaming: isStreaming)
            }
            if !tools.isEmpty { activity }
        }
    }

    private var statuses: [ToolActivityStatus] {
        tools.map { ToolActivityStatus(tool: $0, isStreaming: isStreaming) }
    }

    /// The most relevant state for the whole group: running, then failed, then done.
    private var overallStatus: ToolActivityStatus {
        for status in [ToolActivityStatus.running, .failed, .interrupted] where statuses.contains(status) {
            return status
        }
        return .succeeded
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                #if os(iOS)
                showingActivitySheet = true
                #else
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                #endif
            } label: {
                HStack(spacing: 12) {
                    ToolActivityBadge(status: overallStatus, systemImage: "wrench.and.screwdriver.fill", size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tools.last?.name ?? "Tool calls")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(tools.count == 1 ? "1 tool call" : "\(tools.count) tool calls") · \(summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("tool-activity-toggle")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        Button { selectedID = tool.id } label: {
                            ToolActivityStepRow(
                                tool: tool,
                                status: statuses[index],
                                isFirst: index == 0,
                                isLast: index == tools.count - 1
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tool-activity-\(tool.id)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        #if os(iOS)
        .sheet(isPresented: $showingActivitySheet) {
            activitySheet
        }
        .sensoryFeedback(.selection, trigger: showingActivitySheet)
        #else
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let tool = tools.first(where: { $0.id == selectedID }) {
                ToolActivityDetailView(tool: tool, isStreaming: isStreaming)
            }
        }
        #endif
    }

    #if os(iOS)
    private var activitySheet: some View {
        NavigationStack {
            List {
                ForEach(tools) { tool in
                    Button { selectedID = tool.id } label: {
                        ToolActivityStepRow(
                            tool: tool,
                            status: ToolActivityStatus(tool: tool, isStreaming: isStreaming),
                            isFirst: tool.id == tools.first?.id,
                            isLast: tool.id == tools.last?.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tool-activity-\(tool.id)")
                }
            }
            .navigationTitle("Tool Calls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingActivitySheet = false }
                }
            }
            .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
                if let tool = tools.first(where: { $0.id == selectedID }) {
                    ToolActivityDetailView(tool: tool, isStreaming: isStreaming)
                }
            }
            .sensoryFeedback(.selection, trigger: selectedID)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    #endif

    private var summary: String {
        let counts = Dictionary(grouping: statuses) { $0 }
        return ToolActivityStatus.allCases.compactMap { status in
            guard let count = counts[status]?.count else { return nil }
            return "\(count) \(status.label.lowercased())"
        }.joined(separator: " · ")
    }
}

enum ToolActivityStatus: CaseIterable {
    case running, succeeded, failed, interrupted

    init(tool: ToolCall, isStreaming: Bool) {
        if tool.isError { self = .failed }
        else if tool.result != nil { self = .succeeded }
        else { self = isStreaming ? .running : .interrupted }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    var tint: Color {
        switch self {
        case .running: ClaudeTheme.accent
        case .succeeded: ClaudeTheme.statusSuccess
        case .failed: ClaudeTheme.statusError
        case .interrupted: .secondary
        }
    }
}

/// Display helpers that turn raw tool names and arguments into short readable labels.
enum ToolActivityPresentation {
    /// `mcp__rxcode-ide__ide__get_projects` → "Get projects"; `list_issues` → "List issues".
    static func title(for name: String) -> String {
        if name.lowercased() == "mcptoolcall" { return "MCP tool call" }
        let base = name.components(separatedBy: "__").last(where: { !$0.isEmpty }) ?? name
        let words = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        guard let first = words.first else { return name }
        return first.uppercased() + words.dropFirst()
    }

    /// MCP server name for namespaced tools, e.g. `mcp__github__search` → "github".
    static func source(for name: String) -> String? {
        let parts = name.components(separatedBy: "__").filter { !$0.isEmpty }
        guard parts.count >= 3, parts[0].lowercased() == "mcp" else { return nil }
        return parts[1]
    }

    static func systemImage(for name: String) -> String {
        let lower = (name.components(separatedBy: "__").last ?? name).lowercased()
        switch lower {
        case "read": return "doc.text"
        case "grep", "glob": return "magnifyingglass"
        case "write": return "square.and.pencil"
        case "edit", "multiedit", "multi_edit": return "pencil"
        case "bash": return "terminal"
        case "agent": return "cpu"
        default: break
        }
        if lower.contains("search") || lower.contains("find") || lower.contains("query") { return "magnifyingglass" }
        if lower.hasPrefix("list") || lower.hasPrefix("get") || lower.hasPrefix("read") || lower.hasPrefix("fetch") { return "doc.text.magnifyingglass" }
        if lower.hasPrefix("create") || lower.hasPrefix("add") { return "plus" }
        if lower.hasPrefix("update") || lower.hasPrefix("edit") || lower.hasPrefix("set") { return "pencil" }
        if lower.hasPrefix("delete") || lower.hasPrefix("remove") { return "trash" }
        if lower.hasPrefix("run") || lower.hasPrefix("start") || lower.hasPrefix("trigger") { return "play" }
        return ToolCategory(toolName: name).sfSymbol
    }

    /// One-line hint of what the call targeted, taken from its most descriptive argument.
    static func preview(for input: [String: JSONValue]) -> String? {
        let preferred = ["command", "file_path", "path", "query", "pattern", "url", "title", "name", "description"]
        let value = preferred.lazy.compactMap { input[$0]?.stringValue }.first
            ?? input.keys.sorted().lazy.compactMap { input[$0]?.stringValue }.first
        guard let text = value?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

/// Circular status glyph; shows a spinner while the tool is still running.
private struct ToolActivityBadge: View {
    let status: ToolActivityStatus
    let systemImage: String
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(status.tint.opacity(0.14))
            switch status {
            case .running:
                ProgressView().controlSize(.mini).tint(status.tint)
            case .succeeded:
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(status.tint)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(status.tint)
            case .interrupted:
                Image(systemName: "pause.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.label)
    }
}

/// One timeline step: status badge on a connector line, readable name, and argument hint.
private struct ToolActivityStepRow: View {
    let tool: ToolCall
    let status: ToolActivityStatus
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ToolActivityBadge(status: status, systemImage: ToolActivityPresentation.systemImage(for: tool.name))
                .padding(.top, 10)
                .frame(width: 32)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        connector.frame(height: 10).opacity(isFirst ? 0 : 1)
                        Color.clear.frame(height: 24)
                        connector.opacity(isLast ? 0 : 1)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ToolActivityPresentation.title(for: tool.name))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let source = ToolActivityPresentation.source(for: tool.name) {
                        Text(source)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                    }
                }
                if let preview = ToolActivityPresentation.preview(for: tool.input) {
                    Text(preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if status != .succeeded {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(status == .failed ? AnyShapeStyle(status.tint) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 13)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var connector: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1.5)
    }
}

/// Parameters of a single call. Results are intentionally not shown in the chat UI.
struct ToolActivityDetailView: View {
    let tool: ToolCall
    let isStreaming: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex = 0

    private var status: ToolActivityStatus { ToolActivityStatus(tool: tool, isStreaming: isStreaming) }

    var body: some View {
        let pages = ToolActivityFormatting.pages(ToolActivityFormatting.jsonMarkdown(.object(tool.input)))
        let currentPage = min(pageIndex, pages.count - 1)
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ToolActivityBadge(status: status, systemImage: ToolActivityPresentation.systemImage(for: tool.name), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ToolActivityPresentation.title(for: tool.name)).font(.headline)
                        Text(tool.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text(status.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(status.tint.opacity(0.12), in: Capsule())
                }
                .padding()

                if tool.input.isEmpty {
                    ContentUnavailableView("No Parameters", systemImage: "curlybraces", description: Text("This tool was called without arguments."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Parameters")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            MarkdownContentView(text: pages[currentPage].markdown)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                    // Reset both the scroll position and Markdown renderer on page changes.
                    // Bounded code blocks avoid iOS failing to draw a very tall Text layer.
                    .id(currentPage)
                    .accessibilityIdentifier("tool-detail-content")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if pages.count > 1 && !tool.input.isEmpty {
                    Divider()
                    HStack {
                        Button { pageIndex = max(0, currentPage - 1) } label: {
                            Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Previous page")
                        .disabled(currentPage == 0)
                        Spacer()
                        Menu {
                            Button("First Page") { pageIndex = 0 }
                            Button("Last Page") { pageIndex = pages.count - 1 }
                            Divider()
                            ForEach(pages.indices, id: \.self) { index in
                                Button("Page \(index + 1)") { pageIndex = index }
                            }
                        } label: {
                            Text("Page \(currentPage + 1) of \(pages.count)")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("tool-detail-page-picker")
                        Spacer()
                        Button { pageIndex = min(pages.count - 1, currentPage + 1) } label: {
                            Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Next page")
                        .disabled(currentPage == pages.count - 1)
                    }
                    .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Tool Call")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: pageIndex)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 440)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

enum ToolActivityFormatting {
    struct Page {
        /// Exact source slice, retained independently of display-only fence balancing.
        let source: String
        let markdown: String
    }

    /// Keep each rendered Text layer small, including single-line/minified output.
    /// Reopen fenced code blocks on subsequent pages so JSON stays code throughout.
    static func pages(_ markdown: String) -> [Page] {
        var pages: [Page] = []
        var source = ""
        var characterCount = 0
        var lineCount = 0
        var fence: (opening: String, marker: Character, count: Int)?
        var opening = ""

        func flush() {
            guard !source.isEmpty else { return }
            let closing = fence.map { "\n" + String(repeating: String($0.marker), count: $0.count) } ?? ""
            pages.append(Page(source: source, markdown: opening + source + closing))
            source = ""
            characterCount = 0
            lineCount = 0
            opening = fence.map { $0.opening + "\n" } ?? ""
        }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.drop(while: { $0 == " " })
            let marker = trimmed.first
            let run = trimmed.prefix(while: { $0 == marker }).count
            let isFence = line.count - trimmed.count <= 3 &&
                (marker == "`" || marker == "~") && run >= 3
            // Update fences after appending the whole delimiter, never halfway through it.
            let text = String(line) + (index < lines.count - 1 ? "\n" : "")
            if isFence {
                if characterCount + text.count > 4000 { flush() }
                source += text
                characterCount += text.count
                if let active = fence {
                    if marker == active.marker && run >= active.count &&
                        trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                    }
                } else if let marker {
                    fence = (String(line), marker, run)
                }
            } else {
                for character in text {
                    source.append(character)
                    characterCount += 1
                    if characterCount >= 4000 { flush() }
                }
            }
            lineCount += 1
            if lineCount >= 32 || characterCount >= 4000 { flush() }
        }
        flush()
        return pages.isEmpty ? [Page(source: "", markdown: "The tool returned an empty result.")] : pages
    }

    static func jsonMarkdown(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
        // Results and arguments can themselves contain Markdown code fences.
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(text) + 1))
        return "\(fence)json\n\(text)\n\(fence)"
    }

    static func resultMarkdown(_ result: String) -> String {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)) {
            if case .string(let text) = value { return text }
            if let content = value["content"]?.arrayValue, !content.isEmpty {
                return content.map { block in
                    if let text = block["text"]?.stringValue { return resultMarkdown(text) }
                    return jsonMarkdown(block)
                }.joined(separator: "\n\n")
            }
            return jsonMarkdown(value)
        }
        return result
    }

    static func rawResultMarkdown(_ result: String) -> String {
        let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))) ?? .string(result)
        return jsonMarkdown(value)
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}
