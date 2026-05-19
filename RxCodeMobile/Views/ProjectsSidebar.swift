import SwiftUI
import RxCodeCore

struct ProjectsSidebar: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selected: UUID?
    @Binding var showingBriefing: Bool
    var showsBriefingItem = true
    var usesSelection = true

    var body: some View {
        list
        .navigationTitle("Projects")
        .listStyle(.sidebar)
        .refreshable {
            await state.refreshSnapshot()
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
        if showsBriefingItem {
            Button {
                selected = nil
                showingBriefing = true
            } label: {
                Label("Briefing", systemImage: "doc.text")
                    .font(.headline)
                    .foregroundStyle(showingBriefing ? Color.accentColor : Color.primary)
            }
        }

        Section("Projects") {
            ForEach(state.projects) { project in
                NavigationLink(value: project.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.headline)
                        Text(project.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
