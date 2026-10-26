import RxCodeCore
import SwiftUI

/// Read-only summaries keep project actions in the project's dedicated screens.
struct FlowcyProjectCardSummary: View {
    @Environment(MobileCloudState.self) private var cloud
    let project: CloudProject
    let ci: ProjectCIStatus?
    let release: ReleaseRepoStatus?
    let loading: Bool
    let refreshID: UUID
    @State private var loadingTasks = true
    @State private var taskLoadFailed = false

    private var board: CloudRemoteBoard? { cloud.boards[project.id] }
    private var completed: Int {
        // Cloud sync normalizes every local countsAsDone column to "done".
        board?.tasks.filter { $0.fields.status == TaskStatus.done.rawValue }.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if project.repositoryFullName != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        ciLabel
                        versionLabel
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ciLabel
                        versionLabel
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if let board {
                    HStack {
                        Label("Tasks", systemImage: "checklist")
                        Spacer(minLength: 4)
                        Text(board.tasks.isEmpty ? "No tasks" : "\(completed)/\(board.tasks.count) done")
                            .monospacedDigit()
                    }
                    ProgressView(value: Double(completed), total: Double(max(board.tasks.count, 1)))
                        .tint(.green)
                        .accessibilityLabel("Task progress")
                        .accessibilityValue("\(completed) of \(board.tasks.count) tasks complete")
                    if taskLoadFailed { Text("Task update unavailable").foregroundStyle(.orange) }
                } else {
                    Label(loadingTasks ? "Loading tasks…" : "Tasks unavailable", systemImage: "checklist")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: refreshID) {
            loadingTasks = true
            taskLoadFailed = false
            defer { loadingTasks = false }
            do { try await cloud.loadBoard(project.id) }
            catch {
                guard !MobileCloudState.isCancellation(error) else { return }
                taskLoadFailed = true
            }
        }
    }

    @ViewBuilder private var ciLabel: some View {
        if let ci {
            if ci.found {
                HStack(spacing: 4) {
                    Text("CI")
                    MobileCIStatusChip(status: ci, compact: true)
                }.accessibilityElement(children: .combine)
            } else {
                Label("No CI activity", systemImage: "gearshape.2")
            }
        } else {
            Label(loading ? "Loading CI…" : "CI unavailable", systemImage: "gearshape.2")
        }
    }

    private var versionLabel: some View {
        Label {
            if let release {
                if let version = release.latestVersion, !version.isEmpty {
                    Text("Latest: \(version)")
                } else {
                    Text(release.isManaged ? "No releases" : "Releases not configured")
                }
            } else {
                Text(loading ? "Loading version…" : "Version unavailable")
            }
        } icon: {
            Image(systemName: "tag")
        }
    }
}
