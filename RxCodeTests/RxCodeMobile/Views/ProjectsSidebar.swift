import SwiftUI

struct ProjectsSidebar: View {
    @EnvironmentObject private var state: MobileAppState
    @Binding var selected: UUID?

    var body: some View {
        List(state.projects, selection: $selected) { project in
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
        .navigationTitle("Projects")
        .listStyle(.sidebar)
    }
}
