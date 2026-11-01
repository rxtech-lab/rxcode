import SwiftUI
import RxCodeCore
#if os(macOS)
import AppKit

/// The chat surface for a local decision model: the selected decision's
/// verdict with a probability per option and the web sources it read, an
/// options editor above the composer, and every decision in the thread
/// beside it. Replaces the message list while a decision model is selected.
struct DecisionStudioView<Composer: View>: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    private let composer: Composer

    @State private var selection = StudioSelection()
    @State private var statuses: [String: String] = [:]
    @State private var activity: [String: [VideoGenerationActivity]] = [:]

    init(@ViewBuilder composer: () -> Composer) {
        self.composer = composer()
    }

    private var takes: [GenerationTake] {
        GenerationTake.takes(from: chatBridge.messages, toolName: LocalStudioKind.decision.toolName ?? "",
                             isStreaming: chatBridge.isStreaming, requiresFile: false)
    }

    var body: some View {
        let takes = takes
        let selected = selection.take(in: takes)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if let take = selected {
                        DecisionStage(take: take, status: take.toolCall.flatMap { statuses[$0.id] })
                            .id(take.id)
                            .transition(.opacity)
                    } else {
                        ContentUnavailableView {
                            Label { Text("Make a Decision", bundle: .module) } icon: { Image(systemName: "checklist") }
                        } description: {
                            Text("Add options below and ask a question; \(chatBridge.modelDisplayName) scores each one. With fewer than two options, it judges the question true or false.", bundle: .module)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    DecisionOptionsEditor()
                        .frame(maxWidth: 820)
                        .padding(.horizontal, 8)
                    composer
                        .frame(maxWidth: 820)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !takes.isEmpty {
                Divider()
                StudioTakeList(
                    title: String(localized: "Decisions", bundle: .module),
                    takes: takes,
                    activity: selected?.toolCall.flatMap { activity[$0.id] } ?? [],
                    select: { id in withAnimation(.smooth(duration: 0.25)) { selection.selectedID = id } }
                ) { take in
                    DecisionTakeRow(take: take, status: take.toolCall.flatMap { statuses[$0.id] })
                        .modifier(StudioRowBackground(isSelected: take.id == selected?.id))
                }
                .frame(width: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: takes.isEmpty)
        .studioProgress(statuses: $statuses, activity: $activity)
        .onChange(of: takes.map(\.id)) { old, new in selection.takesChanged(from: old, to: new) }
        .onChange(of: windowState.currentSessionId) { _, _ in
            selection = StudioSelection()
            statuses = [:]
            activity = [:]
        }
    }
}

extension GenerationTake {
    var decision: DecisionResult? { DecisionResult.decode(toolCall?.result) }
    var decisionRequest: DecisionRequest { DecisionRequest.parse(prompt) }
}

// MARK: - Stage

private struct DecisionStage: View {
    @Environment(WindowState.self) private var windowState
    @Environment(ChatBridge.self) private var chatBridge

    let take: GenerationTake
    let status: String?

    var body: some View {
        switch take.phase {
        case .ready:
            if let result = take.decision {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        verdict(result)
                        scores(result)
                        if !result.sources.isEmpty { sources(result.sources) }
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        case .generating:
            StudioWorkingScreen(systemImage: "checklist", status: status, startedAt: take.date, tint: ClaudeTheme.textPrimary) {
                Task { await chatBridge.cancelStreaming() }
            }
        case .missing, .failed:
            ContentUnavailableView {
                Label { Text("Couldn't Decide", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            } description: {
                Text(take.failureMessage)
                    .lineLimit(6)
                    .textSelection(.enabled)
            } actions: {
                Button { askAgain() } label: {
                    Label { Text("Edit Question", bundle: .module) } icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .disabled(take.prompt.isEmpty || chatBridge.isStreaming)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func verdict(_ result: DecisionResult) -> some View {
        let top = result.scores.max { $0.probability < $1.probability }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(result.question)
                    .font(.system(size: ClaudeTheme.size(16), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    StudioActionButton(systemImage: "arrow.counterclockwise", help: String(localized: "Ask again with these options", bundle: .module),
                                       isDisabled: chatBridge.isStreaming) { askAgain() }
                    StudioActionButton(systemImage: "doc.on.doc", help: String(localized: "Copy answer", bundle: .module)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.answer, forType: .string)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ClaudeTheme.textSecondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(ClaudeTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.answer)
                        .font(.system(size: ClaudeTheme.size(22), weight: .bold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                    if let top {
                        Text(top.probability, format: .percent.precision(.fractionLength(1)))
                            .font(.system(size: ClaudeTheme.size(12)).monospacedDigit())
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaudeTheme.accentSubtle, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
            Text([result.calibration, result.model, VideoStudioFormat.madeIn(result.elapsedSeconds)].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
    }

    private func scores(_ result: DecisionResult) -> some View {
        let best = result.scores.map(\.probability).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("Options", bundle: .module)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            ForEach(result.scores.sorted { $0.probability > $1.probability }, id: \.name) { score in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(score.name)
                            .font(.system(size: ClaudeTheme.size(13), weight: score.probability == best ? .semibold : .regular))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                        if !score.detail.isEmpty {
                            Text(score.detail)
                                .font(.caption)
                                .foregroundStyle(ClaudeTheme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(score.probability, format: .percent.precision(.fractionLength(1)))
                            .font(.system(size: ClaudeTheme.size(12)).monospacedDigit())
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ClaudeTheme.surfaceSecondary)
                            Capsule()
                                .fill(score.probability == best ? ClaudeTheme.accent : ClaudeTheme.textTertiary.opacity(0.6))
                                .frame(width: max(4, geometry.size.width * score.probability))
                        }
                    }
                    .frame(height: 8)
                }
                .help(String(localized: "Verdict score \(score.score, format: .number.precision(.fractionLength(2)))", bundle: .module))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func sources(_ sources: [DecisionResult.Source]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text("Web Sources", bundle: .module) } icon: { Image(systemName: "globe") }
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
            ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 3) {
                    if let url = URL(string: source.url) {
                        Link(source.title.isEmpty ? source.url : source.title, destination: url)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                            .lineLimit(1)
                    }
                    Text(URL(string: source.url)?.host() ?? source.url)
                        .font(.caption2)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                    if !source.snippet.isEmpty {
                        Text(source.snippet)
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            }
        }
    }

    /// Restores the question and its options to the composer.
    private func askAgain() {
        let request = take.decisionRequest
        windowState.inputText = request.question
        windowState.decisionDraft.options = request.options
    }
}

// MARK: - Options editor

/// The options the next question is judged against, kept per window.
struct DecisionOptionsEditor: View {
    @Environment(WindowState.self) private var windowState
    @State private var newOption = ""
    @FocusState private var isFieldFocused: Bool

    private var options: [DecisionRequest.Option] { windowState.decisionDraft.options }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: options.count < 2 ? "checkmark.circle.badge.questionmark" : "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Text(options.count < 2
                     ? String(localized: "True or false — add two or more options for a choice", bundle: .module)
                     : String(localized: "Choose among \(options.count) options", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer()
                if !options.isEmpty {
                    Button(String(localized: "Clear", bundle: .module)) {
                        withAnimation(.smooth(duration: 0.2)) { windowState.decisionDraft.options = [] }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            FlowingOptions(options: options) { option in
                withAnimation(.smooth(duration: 0.2)) { windowState.decisionDraft.options.removeAll { $0 == option } }
            }
            HStack(spacing: 6) {
                TextField(String(localized: "Add an option, e.g. billing: payments and refunds", bundle: .module), text: $newOption)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFieldFocused)
                    .onSubmit(add)
                    .accessibilityIdentifier("decision-option-field")
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .disabled(!canAdd)
                .help(String(localized: "Add option", bundle: .module))
            }
        }
        .padding(12)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.6), in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        .padding(.top, 8)
    }

    private var canAdd: Bool {
        let name = parsed.name
        return !name.isEmpty && options.count < DecisionRequest.maxOptions
            && !options.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private var parsed: DecisionRequest.Option {
        let parts = newOption.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return DecisionRequest.Option(name: parts.first ?? "", detail: parts.count > 1 ? parts[1] : "")
    }

    private func add() {
        guard canAdd else { return }
        let option = parsed
        withAnimation(.smooth(duration: 0.2)) { windowState.decisionDraft.options.append(option) }
        newOption = ""
        isFieldFocused = true
    }
}

/// Option chips that wrap onto new lines.
private struct FlowingOptions: View {
    let options: [DecisionRequest.Option]
    let remove: (DecisionRequest.Option) -> Void

    var body: some View {
        if !options.isEmpty {
            ChipFlowLayout(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    HStack(spacing: 4) {
                        Text(option.name)
                            .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        if !option.detail.isEmpty {
                            Text(option.detail)
                                .font(.system(size: ClaudeTheme.size(11)))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                                .lineLimit(1)
                        }
                        Button { remove(option) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Remove option", bundle: .module))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(ClaudeTheme.accentSubtle, in: Capsule())
                    .overlay(Capsule().strokeBorder(ClaudeTheme.accent.opacity(0.3), lineWidth: 1))
                }
            }
        }
    }
}

/// Lays children left to right, wrapping when a row is full.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - List

private struct DecisionTakeRow: View {
    let take: GenerationTake
    let status: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: take.phase == .failed ? "exclamationmark.triangle.fill" : "checklist")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(take.phase == .failed ? ClaudeTheme.statusError : ClaudeTheme.accent)
                .symbolEffect(.pulse, isActive: take.phase == .generating)
                .frame(width: 40, height: 40)
                .background(ClaudeTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(take.decisionRequest.question.isEmpty ? String(localized: "Untitled question", bundle: .module) : take.decisionRequest.question)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                StudioTakeStatus(take: take, status: status, detail: answerDetail)
            }
            Spacer(minLength: 0)
        }
    }

    private var answerDetail: String? {
        guard let result = take.decision, let top = result.scores.max(by: { $0.probability < $1.probability }) else { return nil }
        return "\(result.answer) \(top.probability.formatted(.percent.precision(.fractionLength(0))))"
    }
}
#endif
