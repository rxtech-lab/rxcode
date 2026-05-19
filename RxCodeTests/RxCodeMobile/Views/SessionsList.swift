import SwiftUI

struct SessionsList: View {
    @EnvironmentObject private var state: MobileAppState
    let projectID: UUID
    @Binding var selected: String?

    var body: some View {
        List(filtered, selection: $selected) { session in
            NavigationLink(value: session.id) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(session.title.isEmpty ? "Untitled" : session.title)
                            .font(.headline)
                    }
                    Text(session.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await state.requestNewSession(projectID: projectID) }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
    }

    private var filtered: [SessionSummary] {
        state.sessions
            .filter { $0.projectId == projectID && !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
