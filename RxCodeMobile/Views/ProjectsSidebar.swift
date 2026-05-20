import SwiftUI
import RxCodeCore
import RxCodeSync
import TipKit

struct ProjectsSidebar: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selected: UUID?
    @Binding var showingBriefing: Bool
    var showsBriefingItem = true
    var usesSelection = true
    @State private var searchText = ""
    @State private var showingRemoteFolderPicker = false

    var body: some View {
        list
        .navigationTitle("Projects")
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingRemoteFolderPicker = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("Add Project")
                .popoverTip(MobileTips.RemoteProjectTip(), arrowEdge: .top)
            }
        }
        .sheet(isPresented: $showingRemoteFolderPicker) {
            RemoteFolderPickerView()
                .environmentObject(state)
        }
        .refreshable {
            await state.refreshSnapshot()
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search projects and threads"
        )
        .popoverTip(MobileTips.SearchTip(), arrowEdge: .top)
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .onChange(of: searchText) { _, newValue in
            state.updateSearchQuery(newValue)
        }
        .onDisappear {
            state.updateSearchQuery("")
        }
        .onChange(of: state.lastCreatedProjectID) { _, newValue in
            guard let newValue else { return }
            selected = newValue
            showingBriefing = false
        }
    }

    @ViewBuilder
    private var list: some View {
        if usesSelection {
            List(selection: $selected) {
                listContent
            }
        } else {
            List {
                listContent
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if searchText.isEmpty {
            defaultContent
        } else {
            searchResultsContent
        }
    }

    @ViewBuilder
    private var defaultContent: some View {
        if showsBriefingItem {
            Button {
                selected = nil
                showingBriefing = true
            } label: {
                Label("Briefing", systemImage: "doc.text")
                    .font(.headline)
                    .foregroundStyle(showingBriefing ? Color.accentColor : Color.primary)
            }
            .popoverTip(MobileTips.BriefingTip(), arrowEdge: .trailing)
        }

        Section("Projects") {
            ForEach(state.projects) { project in
                NavigationLink(value: project.id) {
                    projectRow(project)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        let projectMatches = state.projects.filter { project in
            state.searchProjectIDs.contains(project.id)
        }
        let threadHits = state.searchThreadHits
        let projectsByID = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })

        if projectMatches.isEmpty && threadHits.isEmpty {
            Section {
                if state.isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .listRowBackground(Color.clear)
                }
            }
        } else {
            if !projectMatches.isEmpty {
                Section("Projects") {
                    ForEach(projectMatches) { project in
                        NavigationLink(value: project.id) {
                            projectRow(project)
                        }
                    }
                }
            }

            if !threadHits.isEmpty {
                Section("Threads") {
                    ForEach(threadHits) { hit in
                        NavigationLink(value: hit.sessionID) {
                            threadHitRow(hit, project: projectsByID[hit.projectID])
                        }
                    }
                }
            }
        }
    }

    private func threadHitRow(_ hit: SearchHit, project: Project?) -> some View {
        let title = hit.title.isEmpty ? ChatSession.defaultTitle : hit.title
        let showSnippet = !hit.snippet.isEmpty && hit.snippet != title

        return HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)

                if showSnippet {
                    Text(hit.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let project {
                    Text(project.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.body)
                    .lineLimit(1)

                Text(Self.truncatedPath(project.path))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private static func truncatedPath(_ path: String) -> String {
        guard path.hasPrefix("/Users/") else { return path }
        let afterUsers = path.dropFirst("/Users/".count)
        guard let slash = afterUsers.firstIndex(of: "/") else { return path }
        return "~" + afterUsers[slash...]
    }
}
