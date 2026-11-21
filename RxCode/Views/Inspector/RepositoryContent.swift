import RxCodeCore
import SwiftUI

struct RepositoryContent<Content: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(RepositoryStatus.self) private var repository
    @ViewBuilder let content: (GitWorkingTree) -> Content

    var body: some View {
        if let path = appState.sourceControlPath(in: windowState) {
            Group {
                switch path == repository.path ? repository.state : .loading {
                case .loading:
                    ProgressView("Checking repository…").controlSize(.small)
                case .unavailable:
                    ContentUnavailableView {
                        Label("Repository unavailable", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Retry") { Task { await repository.refresh(at: path) } }
                    }
                case .notRepository:
                    GitSetupView(path: path)
                case .ready(let tree):
                    content(tree)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(path)
        } else {
            InspectorEmptyState(title: "No project selected", message: "Select a project to use source control.")
        }
    }
}

private struct GitSetupView: View {
    let path: String
    @Environment(RepositoryStatus.self) private var repository
    @State private var initializing = false
    @State private var error: String?

    var body: some View {
        ContentUnavailableView {
            Label("No Git repository", systemImage: "arrow.triangle.branch")
        } description: {
            Text(path).textSelection(.enabled)
        } actions: {
            Button("Initialize Git") {
                initializing = true
                Task {
                    error = await GitHelper.initRepository(at: path)
                    await repository.refresh(at: path)
                    initializing = false
                }
            }
            .disabled(initializing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if initializing { ProgressView("Initializing…").padding().background(.regularMaterial, in: .rect(cornerRadius: 10)) } }
        .alert("Couldn’t initialize Git", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
