import SwiftUI
import RxCodeCore
import RxCodeSync

enum MobileDraftSessionID {
    private static let prefix = "draft-new"

    static func make(projectID: UUID) -> String {
        "\(prefix):\(projectID.uuidString):\(UUID().uuidString)"
    }

    static func projectID(from id: String) -> UUID? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    static func isDraft(_ id: String) -> Bool {
        projectID(from: id) != nil
    }
}

struct SessionsList: View {
    @EnvironmentObject private var state: MobileAppState
    let projectID: UUID
    @Binding var selected: String?
    var usesSelection = true
    @State private var searchText = ""
    @State private var showingNewThread = false

    /// Number of rows currently materialized. The list grows in `pageSize`
    /// increments as the user scrolls so we never render every thread at once.
    @State private var displayLimit = SessionsList.pageSize
    private static let pageSize = 20

    var body: some View {
        list
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewThread = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showingNewThread) {
            NewThreadSheet(projectID: projectID) { newSessionID in
                selected = newSessionID
            }
            .environmentObject(state)
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search threads"
        )
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .onChange(of: searchText) { _, _ in
            // Restart paging so search results always begin at the top.
            displayLimit = Self.pageSize
        }
        .overlay {
            if filtered.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if usesSelection {
            List(selection: $selected) { sessionRows }
        } else {
            List { sessionRows }
        }
    }

    @ViewBuilder
    private var sessionRows: some View {
        ForEach(visible) { session in
            sessionLink(session)
                .onAppear {
                    if session.id == visible.last?.id { loadMore() }
                }
        }
        if displayLimit < filtered.count {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowSeparator(.hidden)
        }
    }

    /// The slice of `filtered` currently rendered.
    private var visible: [SessionSummary] {
        Array(filtered.prefix(displayLimit))
    }

    private func loadMore() {
        guard displayLimit < filtered.count else { return }
        displayLimit = min(displayLimit + Self.pageSize, filtered.count)
    }

    private func sessionLink(_ session: SessionSummary) -> some View {
        NavigationLink(value: session.id) {
            HStack(spacing: 6) {
                leadingDot(for: session)

                SessionSidebarRow(
                    title: rowTitle(for: session),
                    updatedAt: session.updatedAt,
                    isPinned: session.isPinned,
                    isBackgroundStreaming: session.isStreaming
                )
            }
        }
    }

    /// Status dot shown ahead of the row. A pending permission or question
    /// takes precedence; otherwise a green dot marks a thread whose run
    /// finished while unread, mirroring the desktop sidebar.
    @ViewBuilder
    private func leadingDot(for session: SessionSummary) -> some View {
        if let attention = session.attention {
            statusDot(for: attention)
        } else if session.hasUncheckedCompletion, !session.isStreaming {
            Circle()
                .fill(ClaudeTheme.statusSuccess)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Finished, unread")
        }
    }

    private var filtered: [SessionSummary] {
        let query = searchText.lowercased()
        return state.sessions
            .filter { session in
                guard session.projectId == projectID, !session.isArchived else { return false }
                if query.isEmpty { return true }
                let title = ChatSession.stripAttachmentMarkers(from: session.title).lowercased()
                return title.contains(query)
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private func rowTitle(for session: SessionSummary) -> String {
        let cleaned = ChatSession.stripAttachmentMarkers(from: session.title)
        return cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
    }

    private func statusDot(for attention: SessionAttentionKind) -> some View {
        Circle()
            .fill(attention == .question ? Color.yellow : Color.orange)
            .frame(width: 7, height: 7)
            .accessibilityLabel(attention == .question ? "Question pending" : "Permission pending")
    }
}
