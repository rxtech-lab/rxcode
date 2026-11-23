import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct TrackedPlanMarkdown: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let markdown: String
    let edits: [CodingPlanReview.Edit]
    var reviewer: String?
    var animateEdits = false
    var compact = false
    var addComment: ((Int, String) throws -> Void)?

    private struct Selection: Identifiable {
        let id: Int
        let anchor: CGRect
    }
    @State private var selection: Selection?
    @State private var outgoing: (markdown: String, ranges: [NSRange])?
    @State private var seen: [CodingPlanReview.Edit] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let outgoing {
                PlanStrikethrough(markdown: outgoing.markdown, ranges: outgoing.ranges, compact: compact)
                    .id(outgoing.markdown)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            } else {
                MarkdownContentView(text: markdown, style: compact ? .rxCodeCompact : .rxCodeChat)
                    .annotating(edits.compactMap(\.range)) { index, anchor in
                        selection = Selection(id: index, anchor: anchor)
                    }
                    .popover(item: $selection, attachmentAnchor: .rect(.rect(selection?.anchor ?? .zero))) { selected in
                        if edits.indices.contains(selected.id) {
                            PlanChangePopover(edit: edits[selected.id], reviewer: reviewer,
                                addComment: addComment.map { save in { try save(selected.id, $0) } })
                        }
                    }
                    .transition(.opacity)
            }
        }
        .task(id: animateEdits && !reduceMotion ? edits : []) {
            guard animateEdits, !reduceMotion else { outgoing = nil; return }
            let arrivals = edits.filter { edit in
                !seen.contains { $0.original == edit.original && $0.replacement == edit.replacement }
            }
            seen = edits
            guard !arrivals.isEmpty, let previous = Self.beforeApplying(arrivals, to: markdown) else {
                outgoing = nil
                return
            }
            selection = nil
            outgoing = previous
            do { try await Task.sleep(for: .milliseconds(previous.ranges.isEmpty ? 60 : 370)) }
            catch { return }
            withAnimation(.easeInOut(duration: 0.20)) { outgoing = nil }
        }
    }

    /// Undo only the newly arrived edits for the duration of the strike animation.
    /// Earlier suggestions in the same streaming review stay in their revised form.
    private static func beforeApplying(_ edits: [CodingPlanReview.Edit], to markdown: String) -> (markdown: String, ranges: [NSRange])? {
        let current = markdown as NSString
        var previous = ""
        var ranges: [NSRange] = []
        var start = 0
        for edit in edits {
            guard let range = edit.range, range.location >= start, NSMaxRange(range) <= current.length,
                  current.substring(with: range) == edit.replacement else { return nil }
            previous += current.substring(with: NSRange(location: start, length: range.location - start))
            if !edit.original.isEmpty {
                ranges.append(NSRange(location: previous.utf16.count, length: edit.original.utf16.count))
                previous += edit.original
            }
            start = NSMaxRange(range)
        }
        previous += current.substring(from: start)
        return (previous, ranges)
    }
}

private struct PlanStrikethrough: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let markdown: String
    let ranges: [NSRange]
    var compact = true
    @State private var drawn = false

    var body: some View {
        StrokeText(markdown: markdown, ranges: ranges, compact: compact, progress: drawn || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : .linear(duration: 0.30)) { drawn = true } }
    }

    private struct StrokeText: View, Animatable {
        let markdown: String
        let ranges: [NSRange]
        let compact: Bool
        var progress: CGFloat
        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }
        var body: some View {
            MarkdownContentView(text: markdown, style: compact ? .rxCodeCompact : .rxCodeChat)
                .crossingOut(ranges, progress: min(1, max(0, progress)))
        }
    }
}

private struct PlanChangePopover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let edit: CodingPlanReview.Edit
    let reviewer: String?
    let addComment: ((String) throws -> Void)?
    @State private var commenting = false
    @State private var contentHeight: CGFloat = 160

    var body: some View {
        ScrollView {
            details.onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 308, height: min(contentHeight, 408))
        .padding(16)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coding-plan-change-details")
        .sheet(isPresented: $commenting) {
            if let addComment { PlanCommentSheet(save: addComment) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Original text").font(.headline)
            if edit.original.isEmpty {
                Text("This passage was added.").foregroundStyle(.secondary)
            } else {
                // The header already marks this as replaced text; striking and dimming
                // the whole passage makes it unreadable on the translucent popover.
                MarkdownContentView(text: edit.original, style: .rxCodeCompact)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    .accessibilityIdentifier("coding-plan-original-text")
            }
            Divider()
            Text("Comments").font(.headline)
            let comment = edit.comment.map { CodingPlanReview.feedbackMarkdown($0) } ?? ""
            if !comment.isEmpty {
                commentRow(author: reviewer ?? String(localized: "Reviewer"), markdown: comment)
            }
            let comments = edit.userComments ?? []
            ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                commentRow(author: String(localized: "You"), markdown: comment)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if comment.isEmpty && comments.isEmpty {
                Text("No comments yet.").font(.callout).foregroundStyle(.secondary)
            }
            if addComment != nil {
                Button("Add Comment…", systemImage: "text.bubble") { commenting = true }
                    .accessibilityIdentifier("coding-plan-add-comment")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: edit.userComments?.count)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func commentRow(author: String, markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            MarkdownContentView(text: markdown, style: .rxCodeCompact)
        }
    }
}

private struct PlanCommentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String) throws -> Void
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .accessibilityLabel("Comment")
                .accessibilityIdentifier("coding-plan-comment-text")
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Add Comment")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save Comment") {
                            do { try save(text); dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .frame(minWidth: 360, idealWidth: 440, minHeight: 240, idealHeight: 300, maxHeight: .infinity)
        .onAppear { focused = true }
        .planningError($error)
    }
}
