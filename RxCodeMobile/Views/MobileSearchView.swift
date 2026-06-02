import RxCodeCore
import RxCodeSync
import SwiftUI

/// Adds a search button to the bottom toolbar that presents a full-screen
/// search view when tapped. The full-screen view provides the native iOS/iPadOS
/// search experience with scope filtering (All / Threads / Docs).
///
/// Thread hits reuse the existing search relay (`SearchRequestPayload` →
/// desktop → `SearchResultsPayload`) surfaced as `state.searchThreadHits`.
/// Docs hits ride the same response (`state.searchDocHits`) — mobile never
/// calls the docs API directly. Thread hits push the chat via the enclosing
/// `NavigationStack`; docs open their rendered markdown in a sheet, fetched
/// from the paired desktop on demand.
struct GlobalSearchModifier: ViewModifier {
    @State private var showSearchView = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    showSearchView = true
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Search threads and docs")
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.bar)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .fullScreenCover(isPresented: $showSearchView) {
                FullScreenSearchView(isPresented: $showSearchView)
            }
    }
}

/// Full-screen search view presented when the search button is tapped.
/// Contains a search field, scope picker, and results list with a close button.
struct FullScreenSearchView: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var scope: MobileSearchScope = .all
    @FocusState private var isSearchFocused: Bool

    private var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scope picker
                Picker("Scope", selection: $scope) {
                    ForEach(MobileSearchScope.allCases) { item in
                        Text(scopeLabel(item)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Results
                if isActive {
                    MobileSearchResultsView(searchText: searchText, scope: scope)
                } else {
                    ContentUnavailableView {
                        Label("Search", systemImage: "magnifyingglass")
                    } description: {
                        Text("Search threads and docs")
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search threads and docs")
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isPresented = false
                    }
                }
            }
            .onChange(of: searchText) { _, newValue in
                state.updateSearchQuery(newValue)
            }
            .onDisappear {
                state.updateSearchQuery("")
            }
        }
    }

    /// Scope-bar label. Appends the live match count once a search has settled
    /// so the native segmented control mirrors the desktop's All / Threads /
    /// Docs counts.
    private func scopeLabel(_ item: MobileSearchScope) -> String {
        guard isActive, !state.isSearching else { return item.title }
        let threads = state.searchThreadHits.count
        let docs = state.searchDocHits.count
        let count: Int
        switch item {
        case .all: count = threads + docs
        case .threads: count = threads
        case .docs: count = docs
        }
        return "\(item.title) (\(count))"
    }
}

/// Search content view for the search tab. Displays scope picker and results.
/// The searchable modifier is applied by the parent view.
struct MobileSearchContentView: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var searchText: String
    @State private var scope: MobileSearchScope = .all

    private var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scope picker
            Picker("Scope", selection: $scope) {
                ForEach(MobileSearchScope.allCases) { item in
                    Text(scopeLabel(item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Results
            if isActive {
                MobileSearchResultsView(searchText: searchText, scope: scope)
            } else {
                ContentUnavailableView {
                    Label("Search", systemImage: "magnifyingglass")
                } description: {
                    Text("Search threads and docs")
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .onChange(of: searchText) { _, newValue in
            state.updateSearchQuery(newValue)
        }
        .onDisappear {
            state.updateSearchQuery("")
        }
    }

    private func scopeLabel(_ item: MobileSearchScope) -> String {
        guard isActive, !state.isSearching else { return item.title }
        let threads = state.searchThreadHits.count
        let docs = state.searchDocHits.count
        let count: Int
        switch item {
        case .all: count = threads + docs
        case .threads: count = threads
        case .docs: count = docs
        }
        return "\(item.title) (\(count))"
    }
}

/// The native search-scope categories shared by the `.searchable` scope bar and
/// the inline results view.
enum MobileSearchScope: String, CaseIterable, Identifiable {
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

extension View {
    /// Attach the global thread + docs search (minimized search button +
    /// inline results) to this view. See `GlobalSearchModifier`.
    func globalThreadDocSearch() -> some View {
        modifier(GlobalSearchModifier())
    }
}

/// Inline search results for the active scope. Reads the live results mirrored
/// on `MobileAppState`; the enclosing `GlobalSearchModifier` owns the query
/// field and the native All / Threads / Docs scope bar.
struct MobileSearchResultsView: View {
    @EnvironmentObject private var state: MobileAppState
    let searchText: String
    /// Active category from the native `.searchScopes` scope bar, owned by the
    /// enclosing `GlobalSearchModifier`.
    let scope: MobileSearchScope
    @State private var presentedDoc: DocReference?
    @Namespace private var glassNamespace

    /// Identifies a docs hit to open, driving `.sheet(item:)`. `repo` is the
    /// `owner/repo` the desktop's docs service resolves the document under.
    private struct DocReference: Identifiable {
        let repo: String
        let docId: String
        var id: String { "\(repo):\(docId)" }
    }

    var body: some View {
        results
            .sheet(item: $presentedDoc) { doc in
                MobileDocumentView(repoId: doc.repo, docId: doc.docId)
                    .environmentObject(state)
                    .mobileSheetPresentation()
            }
    }

    // MARK: - Results

    private var showThreads: Bool { scope == .all || scope == .threads }
    private var showDocs: Bool { scope == .all || scope == .docs }

    private var threadHits: [SearchHit] { state.searchThreadHits }
    private var docHits: [DocsSearchHit] { state.searchDocHits }

    private var projectsByID: [UUID: Project] {
        Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
    }

    private var visibleIsEmpty: Bool {
        let threadsEmpty = !showThreads || threadHits.isEmpty
        let docsEmpty = !showDocs || docHits.isEmpty
        return threadsEmpty && docsEmpty
    }

    @ViewBuilder
    private var results: some View {
        if state.isSearching && visibleIsEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Searching…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleIsEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if showThreads, !threadHits.isEmpty {
                        threadsSection
                    }
                    if showDocs, !docHits.isEmpty {
                        docsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var threadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Threads", systemImage: "bubble.left.and.bubble.right", count: threadHits.count)
            GlassEffectContainer(spacing: 10) {
                ForEach(threadHits) { hit in
                    SearchThreadHitCard(
                        hit: hit,
                        project: projectsByID[hit.projectID],
                        namespace: glassNamespace
                    )
                }
            }
        }
    }

    private var docsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Docs", systemImage: "doc.text", count: docHits.count)
            GlassEffectContainer(spacing: 10) {
                ForEach(docHits) { hit in
                    SearchDocHitCard(
                        hit: hit,
                        isEnabled: hit.repositoryFullName != nil,
                        namespace: glassNamespace
                    ) {
                        guard let repo = hit.repositoryFullName else { return }
                        presentedDoc = DocReference(repo: repo, docId: hit.docId)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
    }
}

// MARK: - Doc result card

/// One published-docs match. Mirrors `SearchThreadHitCard` but, since docs are
/// not navigable threads on device, taps invoke `onOpen` (which presents the
/// document's rendered markdown in a sheet) rather than pushing the stack.
struct SearchDocHitCard: View {
    let hit: DocsSearchHit
    var isEnabled: Bool = true
    let namespace: Namespace.ID
    let onOpen: () -> Void

    private var title: String {
        hit.docId.isEmpty ? (hit.repositoryFullName ?? "Document") : hit.docId
    }

    private var hasSnippet: Bool {
        guard let snippet = hit.snippet else { return false }
        return !snippet.isEmpty && snippet != title
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if hasSnippet, let snippet = hit.snippet {
                        Text(snippet)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let repo = hit.repositoryFullName {
                        Text(repo)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassDocCardButtonStyle(isEnabled: isEnabled))
        .glassEffectID("search-doc-\(hit.id)", in: namespace)
        .disabled(!isEnabled)
        .accessibilityIdentifier("search-doc-\(hit.id)")
    }
}
// MARK: - Glass Doc Card Button Style

private struct GlassDocCardButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            }
            .glassEffect(
                Glass.regular.interactive(),
                in: .rect(cornerRadius: 16)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.6)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.primary.opacity(0.05)
        }
        return .clear
    }
}

