import SwiftUI
import RxCodeCore

/// Cmd+K Spotlight-style search across every indexed thread on the device.
/// Results are grouped by project; tapping one switches the current window
/// to that project and selects the session.
struct GlobalSearchOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    @State private var query: String = ""
    @State private var groups: [ThreadSearchService.Group] = []
    @State private var inThreadHits: [ThreadSearchService.InThreadHit] = []
    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false
    @State private var selectedIndex: Int = 0
    @FocusState private var inputFocused: Bool

    /// Flattened selectable rows in display order. Drives arrow-key navigation
    /// and Enter activation; recomputed on every render so it stays in sync
    /// with the current results.
    private enum SelectableRow: Hashable {
        case inThread(UUID)
        case thread(String)
    }

    private var flatRows: [SelectableRow] {
        var rows: [SelectableRow] = []
        for hit in inThreadHits { rows.append(.inThread(hit.id)) }
        for group in groups {
            for hit in group.hits { rows.append(.thread(hit.threadId)) }
        }
        return rows
    }

    private var hasResults: Bool {
        !groups.isEmpty || !inThreadHits.isEmpty
    }

    private var currentThreadTitle: String? {
        guard let id = windowState.currentSessionId else { return nil }
        return appState.allSessionSummaries.first(where: { $0.id == id })?.title
    }

    private let cardWidth: CGFloat = 720
    private let cardHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().background(ClaudeTheme.borderSubtle)
            resultsScroll
            footer
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(ClaudeTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: ClaudeTheme.shadowColor, radius: 24, y: 6)
        .onAppear { inputFocused = true }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            activateSelection()
            return .handled
        }
        .task(id: query) {
            await runSearch()
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: inThreadHits) { _, _ in clampSelection() }
        .onChange(of: groups) { _, _ in clampSelection() }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ClaudeTheme.textSecondary)
                .font(.system(size: ClaudeTheme.size(14), weight: .medium))

            TextField("Search threads by topic, keyword, or feel…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: ClaudeTheme.size(15)))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .focused($inputFocused)
                .onSubmit { Task { await runSearch() } }

            if isSearching {
                ProgressView().controlSize(.small)
            }

            Text("esc")
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 4))
                .onTapGesture { close() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsScroll: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder(
                icon: "sparkles",
                title: "Search past threads",
                subtitle: "Describe what you remember and we'll find it across every project. Indexing runs locally; nothing leaves your Mac."
            )
        } else if !hasResults && hasSearched && !isSearching {
            placeholder(
                icon: "magnifyingglass",
                title: "No matches",
                subtitle: "Try a different phrasing, or wait — the backfill may still be indexing older threads."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !inThreadHits.isEmpty {
                            currentThreadSection
                        }
                        ForEach(groups, id: \.projectId) { group in
                            projectSection(group)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onChange(of: selectedIndex) { _, _ in
                    guard let row = currentSelection() else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        proxy.scrollTo(row, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Current-thread section

    private var currentThreadSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.accent)
                Text(sectionHeader)
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                    .textCase(.uppercase)
                Text("· \(inThreadHits.count)")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(inThreadHits) { hit in
                    inThreadRow(hit: hit)
                }
            }
        }
    }

    private var sectionHeader: String {
        if let title = currentThreadTitle, !title.isEmpty {
            return "In this thread · \(title)"
        }
        return "In this thread"
    }

    private func inThreadRow(hit: ThreadSearchService.InThreadHit) -> some View {
        let row: SelectableRow = .inThread(hit.id)
        let isSelected = currentSelection() == row
        return Button {
            close()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hit.role == .user ? "person.crop.circle" : "sparkle")
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.role == .user ? "You" : "Assistant")
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .textCase(.uppercase)

                    Text(highlightedSnippet(hit: hit))
                        .font(.system(size: ClaudeTheme.size(12)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                Text(hit.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
        .id(row)
    }

    private func highlightedSnippet(hit: ThreadSearchService.InThreadHit) -> AttributedString {
        // Render inline markdown so backticks, **bold**, etc. don't show raw.
        // We then re-find the literal match inside the rendered string so the
        // highlight stays aligned even when the parser shrinks or drops
        // markdown syntax characters.
        var attr = Self.inlineMarkdown(hit.snippet)
        let literal = String(hit.snippet[hit.matchRange])
        if !literal.isEmpty,
           let range = attr.range(of: literal, options: .caseInsensitive) {
            attr[range].inlinePresentationIntent = .stronglyEmphasized
            attr[range].foregroundColor = ClaudeTheme.accent
        }
        return attr
    }

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(title)
                .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(subtitle)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func projectSection(_ group: ThreadSearchService.Group) -> some View {
        let project = appState.projects.first(where: { $0.id == group.projectId })
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text(project?.name ?? "Unknown project")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(group.hits, id: \.threadId) { hit in
                    resultRow(hit: hit)
                }
            }
        }
    }

    private func resultRow(hit: ThreadSearchService.Hit) -> some View {
        let summary = appState.allSessionSummaries.first(where: { $0.id == hit.threadId })
        let title = summary?.title ?? "Untitled thread"
        let snippet = displaySnippet(hit: hit, title: title)
        let threadSummary = appState.threadStore.threadSummaryItem(sessionId: hit.threadId)?.summary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let row: SelectableRow = .thread(hit.threadId)
        let isSelected = currentSelection() == row
        return Button {
            select(hit: hit)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        scoreBadge(hit.score)
                        if summary?.isArchived == true {
                            Text("archived")
                                .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                                .foregroundStyle(ClaudeTheme.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(ClaudeTheme.surfaceSecondary, in: Capsule())
                        }
                    }
                    if let threadSummary, !threadSummary.isEmpty {
                        Text(Self.inlineMarkdown(threadSummary))
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(3)
                    } else if let snippet {
                        Text(snippet)
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(2)
                    } else {
                        Text("Matched on title")
                            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .textCase(.uppercase)
                    }
                }
                Spacer(minLength: 8)
                if let updated = summary?.updatedAt {
                    Text(updated.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
        .id(row)
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
            .fill(isSelected ? ClaudeTheme.accent.opacity(0.14) : ClaudeTheme.surfacePrimary)
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .strokeBorder(isSelected ? ClaudeTheme.accent.opacity(0.55) : .clear, lineWidth: 1)
            )
    }

    /// Show the cosine similarity as a 0–100 chip. Negative scores clamp to 0;
    /// they're rare but possible since NLEmbedding outputs aren't strictly
    /// positive-only.
    private func scoreBadge(_ score: Float) -> some View {
        let clamped = max(0, min(1, score))
        let pct = Int((clamped * 100).rounded())
        return Text("\(pct)%")
            .font(.system(size: ClaudeTheme.size(10), weight: .semibold).monospacedDigit())
            .foregroundStyle(ClaudeTheme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(ClaudeTheme.accent.opacity(0.12), in: Capsule())
    }

    /// Parse a hit snippet for display. Returns `nil` when the snippet would
    /// just repeat the thread title (the indexer stores the title as its own
    /// chunk, so a title-only match would otherwise show the title twice).
    private func displaySnippet(hit: ThreadSearchService.Hit, title: String) -> AttributedString? {
        let cleaned = hit.snippet
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedTitle.isEmpty, cleaned.caseInsensitiveCompare(normalizedTitle) == .orderedSame {
            return nil
        }
        return Self.inlineMarkdown(cleaned)
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(text)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("Local on-device search · archived threads included")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.5))
    }

    // MARK: - Actions

    private func close() {
        windowState.showGlobalSearch = false
    }

    private func currentSelection() -> SelectableRow? {
        let rows = flatRows
        guard !rows.isEmpty else { return nil }
        let clamped = max(0, min(selectedIndex, rows.count - 1))
        return rows[clamped]
    }

    private func moveSelection(by delta: Int) {
        let rows = flatRows
        guard !rows.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = max(0, min(next, rows.count - 1))
    }

    private func clampSelection() {
        let rows = flatRows
        if rows.isEmpty {
            selectedIndex = 0
        } else if selectedIndex >= rows.count {
            selectedIndex = rows.count - 1
        } else if selectedIndex < 0 {
            selectedIndex = 0
        }
    }

    private func activateSelection() {
        guard let row = currentSelection() else { return }
        switch row {
        case .inThread:
            close()
        case .thread(let threadId):
            let id = threadId
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appState.selectSession(id: id, in: windowState)
            }
        }
    }

    private func select(hit: ThreadSearchService.Hit) {
        let id = hit.threadId
        close()
        // Small delay so the overlay's dismiss animation has a frame to start
        // before we trigger the navigation, which can otherwise visibly stall.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            appState.selectSession(id: id, in: windowState)
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            groups = []
            inThreadHits = []
            hasSearched = false
            return
        }
        // Full-text scan of the current thread runs immediately so typing feels
        // responsive even before the semantic search debounces.
        let liveMessages = appState.messages(in: windowState)
        inThreadHits = ThreadSearchService.searchInThread(q, in: liveMessages)

        // Debounce: wait briefly so we don't re-embed on every keystroke.
        try? await Task.sleep(for: .milliseconds(180))
        if Task.isCancelled { return }
        if q != query.trimmingCharacters(in: .whitespacesAndNewlines) { return }

        isSearching = true
        let results = await appState.searchService.search(q, limit: 50)
        if Task.isCancelled { return }
        if q == query.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Drop the current thread from the semantic groups when we already
            // have in-thread literal matches — same thread shouldn't appear twice.
            let currentId = inThreadHits.isEmpty ? nil : windowState.currentSessionId
            groups = results.compactMap { group in
                let filtered = group.hits.filter { $0.threadId != currentId }
                guard !filtered.isEmpty else { return nil }
                return ThreadSearchService.Group(projectId: group.projectId, hits: filtered)
            }
            hasSearched = true
        }
        isSearching = false
    }
}
