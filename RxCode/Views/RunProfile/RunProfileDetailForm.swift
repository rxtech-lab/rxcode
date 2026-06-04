import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Detail form

struct RunProfileDetailForm: View {
    @Binding var profile: RunProfile
    let project: Project

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
            } header: {
                Text("Configuration")
            }

            ProfileCommandSections(
                profileID: profile.id,
                project: project,
                type: $profile.type,
                bash: $profile.bash,
                xcode: $profile.xcode,
                make: $profile.make,
                package: $profile.package
            )

            environmentsSection

            stepsSection(
                title: "Before Launch",
                steps: Binding(get: { profile.beforeSteps }, set: { profile.beforeSteps = $0 })
            )

            stepsSection(
                title: "After Launch",
                steps: Binding(get: { profile.afterSteps }, set: { profile.afterSteps = $0 })
            )
        }
        .formStyle(.grouped)
        .onAppear {
            AnalyticsService.shared.log(.runProfileEditorOpened, parameters: [
                "project_id": project.id.uuidString,
                "profile_type": profile.type.rawValue,
            ])
        }
    }
}
