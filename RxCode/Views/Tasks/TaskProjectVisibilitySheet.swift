import RxCodeCore
import SwiftUI

/// Keeps restoration available even when every overview card is hidden.
struct TaskProjectVisibilityButton: View {
    @Environment(AppState.self) private var appState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Project Cards", systemImage: "eye")
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Hide or restore project cards on the Tasks page")
        .accessibilityIdentifier("task-project-card-visibility")
        .sheet(isPresented: $isPresented) {
            TaskProjectVisibilitySheet()
                .environment(appState)
        }
    }
}

struct TaskProjectVisibilitySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project Cards")
                .font(.headline)
            Text("Choose which project cards appear on the Tasks page. Hiding a card does not delete its project or tasks.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            List {
                ForEach(appState.projects) { project in
                    visibilityRow(
                        name: project.name,
                        icon: "folder",
                        hidden: appState.hiddenTaskProjectIds.contains(project.id),
                        id: project.id.uuidString
                    ) { hidden in
                        if hidden {
                            appState.hiddenTaskProjectIds.insert(project.id)
                        } else {
                            appState.hiddenTaskProjectIds.remove(project.id)
                        }
                    }
                }
                ForEach(appState.unopenedCloudProjects) { cloud in
                    visibilityRow(
                        name: cloud.title,
                        icon: "icloud",
                        hidden: appState.hiddenCloudProjectIds.contains(cloud.id),
                        id: cloud.id
                    ) { hidden in
                        appState.setCloudProject(cloud.id, hidden: hidden)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .overlay(alignment: .topTrailing) {
            if let feedback {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("task-project-visibility-status")
            }
        }
        .task(id: feedback) {
            guard feedback != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            feedback = nil
        }
    }

    private func visibilityRow(
        name: String, icon: String, hidden: Bool, id: String,
        update: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            Label(name, systemImage: icon)
                .lineLimit(1)
                .help(name)
            Spacer()
            Button(hidden ? "Show" : "Hide", systemImage: hidden ? "eye" : "eye.slash") {
                update(!hidden)
                feedback = hidden ? "\(name) restored" : "\(name) hidden"
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(hidden ? "Show" : "Hide") \(name)")
            .accessibilityIdentifier("task-project-visibility-\(id)")
        }
    }
}
