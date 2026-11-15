import RxCodeCore
import SwiftUI

/// One project tile in the Projects grid. Read-only: actions live in the
/// project's own workspace, which the surrounding button opens.
struct FlowcyProjectCard: View {
    @Environment(MobileCloudState.self) private var cloud
    let project: CloudProject
    let ci: ProjectCIStatus?
    let release: ReleaseRepoStatus?
    let loading: Bool
    let refreshID: UUID
    @State private var loadingTasks = true
    @State private var taskLoadFailed = false

    private var board: CloudRemoteBoard? { cloud.boards[project.id] }
    private var total: Int { board?.tasks.count ?? 0 }
    private var completed: Int {
        // Cloud sync normalizes every local countsAsDone column to "done".
        board?.tasks.filter { $0.fields.status == TaskStatus.done.rawValue }.count ?? 0
    }
    private var tint: Color { Self.tint(for: project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if project.repositoryFullName != nil { pills }
            Spacer(minLength: 0)
            taskFooter
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(Self.monogram(project.title))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Label {
                    Text(project.repositoryFullName ?? String(localized: "Standalone project")).lineLimit(1)
                } icon: {
                    Image(systemName: project.repositoryFullName == nil ? "folder" : "chevron.left.forwardslash.chevron.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    private var pills: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ciPill; versionPill }
            VStack(alignment: .leading, spacing: 6) { ciPill; versionPill }
        }
    }

    @ViewBuilder private var ciPill: some View {
        if let ci, ci.found {
            MobileCIStatusChip(status: ci)
        } else {
            MobileCardTag(text: ci == nil ? (loading ? String(localized: "Loading CI…") : String(localized: "CI unavailable"))
                                          : String(localized: "No CI runs"),
                          systemImage: "gearshape.2")
        }
    }

    private var versionPill: some View {
        let text: String
        var tint: Color = .secondary
        if let release {
            if let version = release.latestVersion, !version.isEmpty {
                text = version
                tint = .indigo
            } else {
                text = release.isManaged ? String(localized: "No releases") : String(localized: "Releases off")
            }
        } else {
            text = loading ? String(localized: "Loading…") : String(localized: "Version unavailable")
        }
        return MobileCardTag(text: text, systemImage: "tag", tint: tint)
    }

    private var taskFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(taskTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(taskLoadFailed ? .orange : .secondary)
                Spacer(minLength: 4)
                if board != nil, total > 0 {
                    Text("\(completed)/\(total)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    if total > 0 {
                        Capsule()
                            .fill(completed == total ? Color.green : tint)
                            .frame(width: max(6, proxy.size.width * Double(completed) / Double(total)))
                    }
                }
            }
            .frame(height: 6)
            .redacted(reason: board == nil && loadingTasks ? .placeholder : [])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Task progress")
        .accessibilityValue(board == nil ? taskTitle : "\(completed) of \(total) tasks complete")
    }

    private var taskTitle: String {
        if taskLoadFailed && board != nil { return String(localized: "Task update unavailable") }
        guard board != nil else {
            return loadingTasks ? String(localized: "Loading tasks…") : String(localized: "Tasks unavailable")
        }
        if total == 0 { return String(localized: "No tasks yet") }
        return completed == total ? String(localized: "All tasks done") : String(localized: "\(total - completed) open tasks")
    }

    static func monogram(_ title: String) -> String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    /// A stable accent per project so tiles stay recognizable across launches.
    static func tint(for id: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan, .mint, .brown]
        let hash = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
