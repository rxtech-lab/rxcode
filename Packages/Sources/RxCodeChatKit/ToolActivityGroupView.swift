import SwiftUI
import RxCodeCore

/// Compact tool activity shared by mobile transcripts and account Agent Chat.
public struct ToolActivityGroupView: View {
    let tools: [ToolCall]
    let isStreaming: Bool
    @State private var isExpanded = false
    @State private var selectedID: String?

    public init(tools: [ToolCall], isStreaming: Bool = false) {
        self.tools = tools
        self.isStreaming = isStreaming
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tools.count == 1 ? "1 tool call" : "\(tools.count) tool calls")
                            .font(.subheadline.weight(.medium))
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("tool-activity-toggle")

            if isExpanded {
                ForEach(tools) { tool in
                    Divider()
                    Button { selectedID = tool.id } label: {
                        HStack(spacing: 10) {
                            ToolActivityStatusView(status: ToolActivityStatus(tool: tool, isStreaming: isStreaming))
                            Text(tool.name)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .frame(minHeight: 44)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tool-activity-\(tool.id)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let tool = tools.first(where: { $0.id == selectedID }) {
                ToolActivityDetailView(tool: tool, isStreaming: isStreaming)
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: isExpanded)
        .sensoryFeedback(.selection, trigger: selectedID)
        #endif
    }

    private var summary: String {
        let counts = Dictionary(grouping: tools) { ToolActivityStatus(tool: $0, isStreaming: isStreaming) }
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
}

private struct ToolActivityStatusView: View {
    let status: ToolActivityStatus

    var body: some View {
        Label {
            Text(status.label).font(.caption)
        } icon: {
            switch status {
            case .running: ProgressView().controlSize(.small)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(ClaudeTheme.statusSuccess)
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ClaudeTheme.statusError)
            case .interrupted: Image(systemName: "pause.circle").foregroundStyle(.secondary)
            }
        }
    }
}

struct ToolActivityDetailView: View {
    let tool: ToolCall
    let isStreaming: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var section = Section.result
    @State private var pageIndex = 0

    private enum Section: String, CaseIterable {
        case result = "Result", parameters = "Parameters", raw = "Raw Result"
    }

    private var markdown: String {
        if section == .parameters {
            return ToolActivityFormatting.jsonMarkdown(.object(tool.input))
        }
        guard let result = tool.result else {
            return tool.isError ? "The tool failed without a result." :
                isStreaming ? "Waiting for the tool result…" : "No result was received."
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The tool returned an empty result."
        }
        let rendered = section == .raw ? ToolActivityFormatting.rawResultMarkdown(result) :
            ToolActivityFormatting.resultMarkdown(result)
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
            "The tool returned an empty result." : rendered
    }

    var body: some View {
        let content = markdown
        let pages = ToolActivityFormatting.pages(content)
        let currentPage = min(pageIndex, pages.count - 1)
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tool details", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if content == "The tool returned an empty result." {
                    ContentUnavailableView {
                        Label("No Result", systemImage: "doc.text")
                    } description: {
                        MarkdownContentView(text: content)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        MarkdownContentView(text: pages[currentPage].markdown)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    // Reset both the scroll position and Markdown renderer on page changes.
                    // Bounded code blocks avoid iOS failing to draw a very tall Text layer.
                    .id("\(section.rawValue)-\(currentPage)")
                    .accessibilityIdentifier("tool-detail-content")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if pages.count > 1 {
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
            .onChange(of: section) { _, _ in pageIndex = 0 }
            .navigationTitle(tool.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: section)
            .sensoryFeedback(.selection, trigger: pageIndex)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ToolActivityStatusView(status: ToolActivityStatus(tool: tool, isStreaming: isStreaming))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 440)
        #else
        .presentationDetents([.large])
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
