import SwiftUI

struct FlowcyProjectForm: View {
    @Environment(MobileCloudState.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    let onSave: () async -> Void
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form { TextField("Project name", text: $name).accessibilityIdentifier("flowcy-project-name") }
                .navigationTitle("New Project")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            saving = true
                            MobileHaptics.buttonTap()
                            Task {
                                defer { saving = false }
                                do {
                                    try await cloud.createProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                                    await onSave()
                                    MobileHaptics.connected()
                                    dismiss()
                                } catch { self.error = error.localizedDescription; MobileHaptics.connectionError() }
                            }
                        }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .overlay { if saving { ProgressView("Creating project…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
                .alert("Could Not Create Project", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }.interactiveDismissDisabled(saving)
    }
}
