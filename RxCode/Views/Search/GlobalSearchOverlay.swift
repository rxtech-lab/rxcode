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
    @State private var isSearchingThreads: Bool = false
    @State private var isSearchingDocs: Bool = false
    @State private var hasSearched: Bool = false
    @State private var selectedIndex: Int = 0
    @State private var filter: SearchFilter = .all
    @FocusState private var inputFocused: Bool

    /// Which kind of result the list is scoped to. `.all` interleaves threads
    /// and docs; the others narrow the list to a single source.
    private enum SearchFilter: String, CaseIterable, Identifiable {
        case all
        case threads
        case docs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .threads: return "Threads"
            case .docs: return "Docs"
            }
        }
    }

    private var showThreads: Bool { filter != .docs }
    private var showDocs: Bool { filter != .threads }

    /// Docs results live alongside threads in a single, unified result list —
    /// one query searches on-device threads and github-pm's docs index at once,
    /// with no scope to pick.
    @State private var docsHits: [DocsSearchHit] = []
    @State private var docsError: String?
    @State private var selectedDoc: DocsSearchHit?

    private var isSearching: Bool { isSearchingThreads || isSearchingDocs }

    /// Flattened selectable rows in display order. Drives arrow-key navigation
    /// and Enter activation; recomputed on every render so it stays in sync
    /// with the current results.
    private enum SelectableRow: Hashable {
        case inThread(UUID)
        case thread(String)
        case doc(String)
    }

    private var flatRows: [SelectableRow] {
        var rows: [SelectableRow] = []
        if showThreads {
            for hit in inThreadHits { rows.append(.inThread(hit.id)) }
            for group in groups {
                for hit in group.hits { rows.append(.thread(hit.threadId)) }
            }
        }
        if showDocs {
            for hit in docsHits { rows.append(.doc(hit.id)) }
        }
        return rows
    }

    private var hasResults: Bool {
        if showThreads, !groups.isEmpty || !inThreadHits.isEmpty { return true }
        if showDocs, !docsHits.isEmpty { return true }
        return false
    }

    private var currentThreadTitle: String? {
        guard let id = windowState.currentSessionId else { return nil }
        return appState.allSessionSummaries.first(where: { $0.id == id })?.title
    }

    private let cardWidth: CGFloat = 720
    private let cardHeight: CGFloat = 520

    /// How long to wait after the last keystroke before kicking off the
    /// expensive work (semantic thread embedding + the docs network call).
    /// The cheap in-thread literal scan still runs immediately so typing
    /// stays responsive.
    private let debounceDelay: Duration = .seconds(1)

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filterTabs
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
        .onChange(of: filter) { _, _ in selectedIndex = 0 }
        .onChange(of: inThreadHits) { _, _ in clampSelection() }
        .onChange(of: groups) { _, _ in clampSelection() }
        .onChange(of: docsHits) { _, _ in clampSelection() }
        .sheet(item: $selectedDoc) { hit in
            DocsDocumentDetailView(
                repoId: hit.repositoryFullName,
                docId: hit.docId,
                fallbackTitle: hit.title ?? hit.docId,
                fallbackContent: hit.snippet,
                originalLink: hit.originalLink
            )
            .environment(appState)
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ClaudeTheme.textSecondary)
                .font(.system(size: ClaudeTheme.size(14), weight: .medium))

            TextField("Search threads and docs…", text: $query)
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

    // MARK: - Filter tabs

    private var filterTabs: some View {
        HStack(spacing: 6) {
            ForEach(SearchFilter.allCases) { item in
                filterTab(item)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func filterTab(_ item: SearchFilter) -> some View {
        let isSelected = filter == item
        let count = resultCount(for: item)
        return Button {
            filter = item
        } label: {
            HStack(spacing: 5) {
                Text(item.title)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: ClaudeTheme.size(11), weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                }
            }
            .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(isSelected ? ClaudeTheme.accent.opacity(0.14) : ClaudeTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .strokeBorder(isSelected ? ClaudeTheme.accent.opacity(0.45) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
    }

    /// Total matches a given filter would surface, or `nil` before any search
    /// has run (so the tabs stay clean until there's something to count).
    private func resultCount(for item: SearchFilter) -> Int? {
        guard hasSearched else { return nil }
        let threadCount = inThreadHits.count + groups.reduce(0) { $0 + $1.hits.count }
        switch item {
        case .all: return threadCount + docsHits.count
        case .threads: return threadCount
        case .docs: return docsHits.count
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsScroll: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholder(
                icon: "sparkles",
                title: "Search threads and docs",
                subtitle: "Describe what you remember — we search every project's threads on-device and your published docs at once. Nothing manual to pick."
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
                        if showThreads {
                            if !inThreadHits.isEmpty {
                                currentThreadSection
                            }
                            ForEach(groups, id: \.projectId) { group in
                                projectSection(group)
                            }
                        }
                        if showDocs, !docsHits.isEmpty {
                            docsSection
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

    // MARK: - Docs section

    private var docsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text("Documentation")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                Text("· \(docsHits.count)")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(docsHits) { hit in
                    docsRow(hit: hit)
                }
            }
        }
    }

    private func docsRow(hit: DocsSearchHit) -> some View {
        let row: SelectableRow = .doc(hit.id)
        let isSelected = currentSelection() == row
        return Button {
            selectedDoc = hit
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(hit.title ?? hit.docId)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        if let score = hit.score { scoreBadge(Float(score)) }
                    }
                    if let repo = hit.repository {
                        Text(repo)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    if let snippet = hit.snippet, !snippet.isEmpty {
                        Text(Self.inlineMarkdown(snippet))
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
        .id(row)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: ClaudeTheme.size(10)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(docsError == nil
                 ? "Threads searched on-device · docs from the docs service"
                 : "Threads on-device · docs unavailable: \(docsError ?? "")")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
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
        case .doc(let hitId):
            selectedDoc = docsHits.first(where: { $0.id == hitId })
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
            docsHits = []
            docsError = nil
            hasSearched = false
            return
        }

        // The cheap, literal in-thread scan runs immediately so typing feels
        // responsive even before the expensive work kicks in.
        let liveMessages = appState.messages(in: windowState)
        inThreadHits = ThreadSearchService.searchInThread(q, in: liveMessages)

        // Single debounce gate: wait briefly so we don't re-embed threads or
        // hit the docs API on every keystroke. `.task(id: query)` cancels this
        // sleep the moment the query changes, so only the final pause fires.
        try? await Task.sleep(for: debounceDelay)
        if Task.isCancelled { return }
        if q != query.trimmingCharacters(in: .whitespacesAndNewlines) { return }

        // Threads (on-device) and docs (network) run together — one query, one
        // result list — now that the debounce has settled.
        async let docsRun: Void = runDocsSearch(q)
        await runThreadsSearch(q)
        await docsRun
    }

    private func runThreadsSearch(_ q: String) async {
        isSearchingThreads = true
        let results = await appState.searchService.search(q, limit: 50)
        if Task.isCancelled { isSearchingThreads = false; return }
        if q == query.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Drop the current thread from the semantic groups when we already
            // have in-thread literal matches — same thread shouldn't appear twice.
            let currentId = inThreadHits.isEmpty ? nil : windowState.currentSessionId
            // Hide hits that belong to a project no longer in the projects list.
            // These are orphans from a deleted project; surfacing them as
            // "Unknown project" is confusing, so we drop them from the results.
            let knownProjectIds = Set(appState.projects.map(\.id))
            groups = results.compactMap { group in
                guard knownProjectIds.contains(group.projectId) else { return nil }
                let filtered = group.hits.filter { $0.threadId != currentId }
                guard !filtered.isEmpty else { return nil }
                return ThreadSearchService.Group(projectId: group.projectId, hits: filtered)
            }
            hasSearched = true
        }
        isSearchingThreads = false
    }

    /// Semantic docs search across every docs repo the user can read. The
    /// caller already debounced before invoking this.
    private func runDocsSearch(_ q: String) async {
        docsError = nil
        if Task.isCancelled { return }
        if q != query.trimmingCharacters(in: .whitespacesAndNewlines) { return }

        isSearchingDocs = true
        defer { isSearchingDocs = false }
        do {
            let hits = try await appState.docs.search(query: q, repo: nil, limit: 30)
            if Task.isCancelled { return }
            if q == query.trimmingCharacters(in: .whitespacesAndNewlines) {
                docsHits = hits
                hasSearched = true
            }
        } catch {
            if Task.isCancelled { return }
            docsHits = []
            docsError = error.localizedDescription
            hasSearched = true
        }
    }
}
