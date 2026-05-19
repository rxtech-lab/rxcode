import SwiftUI
import RxCodeCore

struct ProjectsSidebar: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selected: UUID?
    @Binding var showingBriefing: Bool

    var body: some View {
        List(selection: $selected) {
            Button {
                selected = nil
                showingBriefing = true
            } label: {
                Label("Briefing", systemImage: "doc.text")
                    .font(.headline)
                    .foregroundStyle(showingBriefing ? Color.accentColor : Color.primary)
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
        .navigationTitle("Projects")
        .listStyle(.sidebar)
    }
}
