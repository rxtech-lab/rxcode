import ExtensionFoundation
import SwiftUI

struct ExtensionsSettingsTab: View {
    @State private var monitor: AppExtensionPoint.Monitor?
    @State private var failure: String?
    @State private var showingBrowser = false

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Extension discovery failed", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else if let monitor {
                if monitor.identities.isEmpty {
                    ContentUnavailableView("No System-Enabled Extensions", systemImage: "puzzlepiece.extension",
                                           description: Text("Use Manage Extensions to enable an installed contributor."))
                } else {
                    List(monitor.identities, id: \.self) { identity in
                        LabeledContent(identity.localizedName, value: identity.bundleIdentifier)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            Button("Manage Extensions…") { showingBrowser = true }
        }
        .sheet(isPresented: $showingBrowser) {
            NavigationStack {
                SystemExtensionBrowser()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Manage Extensions")
                    .toolbar { Button("Done") { showingBrowser = false } }
            }
            .frame(minWidth: 540, minHeight: 480)
        }
        .task {
            do {
                let available = try await AppExtensionPoint.Monitor(appExtensionPoint: .workspaceContributions)
                try await available.addAppExtensionPoint(.workspaceServices)
                monitor = available
            }
            catch { failure = error.localizedDescription }
        }
    }
}
