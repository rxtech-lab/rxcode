import RxCodeCore
import SwiftUI

/// Visibility and accessible ordering controls remain available when every card is hidden.
struct MobileProjectCardsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let projects: [Project]
    let isHidden: (Project) -> Bool
    let setHidden: (Bool, Project) -> Void
    let reorder: ([Project]) -> Void
    @State private var feedback: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(projects) { project in
                        HStack {
                            Label(project.name, systemImage: project.isCloud ? "icloud" : "folder")
                                .lineLimit(2)
                            Spacer()
                            Button(isHidden(project) ? "Show" : "Hide",
                                   systemImage: isHidden(project) ? "eye" : "eye.slash") {
                                let hidden = !isHidden(project)
                                setHidden(hidden, project)
                                feedback = hidden ? "\(project.name) hidden" : "\(project.name) restored"
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("\(isHidden(project) ? "Show" : "Hide") \(project.name)")
                            .accessibilityIdentifier("tasks-project-visibility-\(project.id.uuidString)")
                        }
                    }
                    .onMove { source, destination in
                        var reordered = projects
                        reordered.move(fromOffsets: source, toOffset: destination)
                        reorder(reordered)
                        feedback = "Project cards reordered"
                    }
                } footer: {
                    Text("Drag the handles to reorder project cards. Hiding a card keeps its project and tasks. Long press a card's title on the Tasks page to drag it directly.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .overlay {
                if projects.isEmpty {
                    ContentUnavailableView("No Project Cards", systemImage: "rectangle.stack",
                                           description: Text("Your project cards will appear here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let feedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("tasks-project-visibility-status")
                }
            }
            .task(id: feedback) {
                guard feedback != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self.feedback = nil
            }
            .navigationTitle("Project Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { MobileHaptics.buttonTap(); dismiss() }
                }
            }
        }
    }
}
