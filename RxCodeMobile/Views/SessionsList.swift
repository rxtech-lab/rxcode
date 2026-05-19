import SwiftUI
import RxCodeCore
import RxCodeSync

enum MobileDraftSessionID {
    private static let prefix = "draft-new"

    static func make(projectID: UUID) -> String {
        "\(prefix):\(projectID.uuidString):\(UUID().uuidString)"
    }

    static func projectID(from id: String) -> UUID? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    static func isDraft(_ id: String) -> Bool {
        projectID(from: id) != nil
    }
}

struct SessionsList: View {
    @EnvironmentObject private var state: MobileAppState
    let projectID: UUID
    @Binding var selected: String?
    var usesSelection = true

    var body: some View {
        list
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selected = MobileDraftSessionID.make(projectID: projectID)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if usesSelection {
            List(filtered, selection: $selected) { session in
                sessionLink(session)
            }
        } else {
            List(filtered) { session in
                sessionLink(session)
            }
        }
    }

    private func sessionLink(_ session: SessionSummary) -> some View {
        NavigationLink(value: session.id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let attention = session.attention {
                        statusDot(for: attention)
                    }

                    Text(displayTitle(for: session))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 6)

                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    if session.isStreaming {
                        compactProgress(for: session.progress)
                    } else {
                        Text(session.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if session.isStreaming {
                    progressBar(for: session.progress)
                } else if let attention = session.attention {
                    Text(attention == .question ? "Question pending" : "Permission pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var filtered: [SessionSummary] {
        state.sessions
            .filter { $0.projectId == projectID && !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private func displayTitle(for session: SessionSummary) -> String {
        let cleaned = ChatSession.stripAttachmentMarkers(from: session.title)
        let resolved = cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
        return resolved.prefix(1).uppercased() + resolved.dropFirst()
    }

    private func statusDot(for attention: SessionAttentionKind) -> some View {
        Circle()
            .fill(attention == .question ? Color.yellow : Color.orange)
            .frame(width: 7, height: 7)
            .accessibilityLabel(attention == .question ? "Question pending" : "Permission pending")
    }

    @ViewBuilder
    private func compactProgress(for progress: SessionProgressSnapshot?) -> some View {
        if let progress, progress.total > 0 {
            Text("\(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func progressBar(for progress: SessionProgressSnapshot?) -> some View {
        if let progress, progress.total > 0 {
            ProgressView(value: Double(progress.done), total: Double(progress.total))
                .tint(progress.done == progress.total ? .green : .accentColor)
                .accessibilityLabel("Todos \(progress.done) of \(progress.total)")
        } else {
            ProgressView()
                .accessibilityLabel("Response in progress")
        }
    }
}
