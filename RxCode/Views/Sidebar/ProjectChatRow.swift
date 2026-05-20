import SwiftUI
import RxCodeCore

// MARK: - ChatStatus

/// Per-chat status derived from streaming state, pending permissions, and errors.
public enum ChatStatus: Sendable, Equatable {
    case idle
    case streaming
    case awaitingPermission
    case done
    case error(String)
}

// MARK: - ChatTodoProgress

struct ChatTodoProgress: Sendable, Equatable {
    let done: Int
    let total: Int
    let inProgress: Bool

    init(done: Int, total: Int, inProgress: Bool) {
        self.done = done
        self.total = total
        self.inProgress = inProgress
    }

    init(todos: [TodoItem]) {
        self.done = todos.filter { $0.status == .completed }.count
        self.total = todos.count
        self.inProgress = todos.contains { $0.status == .inProgress }
    }
}

// MARK: - StatusBadgeDot

struct StatusBadgeDot: View {
    let status: ChatStatus

    private var color: Color {
        switch status {
        case .idle: return ClaudeTheme.textTertiary.opacity(0.4)
        case .streaming: return ClaudeTheme.accent
        case .awaitingPermission: return Color.yellow
        case .done: return ClaudeTheme.statusSuccess
        case .error: return ClaudeTheme.statusError
        }
    }

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(shouldPulse ? (pulse ? 1.4 : 1.0) : 1.0)
            .opacity(shouldPulse ? (pulse ? 0.65 : 1.0) : 1.0)
            .onAppear {
                guard shouldPulse else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }

    private var shouldPulse: Bool {
        switch status {
        case .streaming, .awaitingPermission: return true
        default: return false
        }
    }
}

// MARK: - ProjectChatRow

struct ProjectChatRow: View {
    let summary: ChatSession.Summary
    let isCurrent: Bool
    let status: ChatStatus
    let todoProgress: ChatTodoProgress?
    let onSelect: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var isActiveStatus: Bool {
        switch status {
        case .awaitingPermission, .done, .error: return true
        default: return false
        }
    }

    /// Title cleaned of `[Attached image: ...]` / `[ImageN]` / etc. markers that may
    /// be baked into older persisted summaries from before title stripping landed.
    private var displayTitle: String {
        let cleaned = ChatSession.stripAttachmentMarkers(from: summary.title)
        let resolved = cleaned.isEmpty ? ChatSession.defaultTitle : cleaned
        return resolved.prefix(1).uppercased() + resolved.dropFirst()
    }

    var body: some View {
        HStack(spacing: 8) {
            if isActiveStatus {
                statusIndicator
            }

            Text(displayTitle)
                .font(.system(size: ClaudeTheme.size(13), weight: isCurrent ? .medium : .regular))
                .foregroundStyle(isCurrent ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if summary.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: ClaudeTheme.size(9)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }

            if case .streaming = status {
                CompactSessionProgressView(progress: todoProgress)
                    .frame(width: 28, alignment: .trailing)
            } else {
                Text(Self.compactElapsedTime(since: summary.updatedAt))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                .fill(
                    isCurrent ? ClaudeTheme.accentSubtle :
                        (isHovered ? ClaudeTheme.surfaceSecondary.opacity(0.45) : Color.clear)
                )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help(displayTitle)
        .onTapGesture { onSelect() }
        .contextMenu {
            Button { onRename() } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { onTogglePin() } label: {
                if summary.isPinned {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin", systemImage: "pin")
                }
            }
            Button { onToggleArchive() } label: {
                if summary.isArchived {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                } else {
                    Label("Archive", systemImage: "archivebox")
                }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .awaitingPermission, .done, .error:
            StatusBadgeDot(status: status)
        case .idle, .streaming:
            EmptyView()
        }
    }

    private static func compactElapsedTime(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "0m" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w" }

        return "\(days / 365)y"
    }
}

// MARK: - CompactSessionProgressView

private struct CompactSessionProgressView: View {
    let progress: ChatTodoProgress?

    private var fraction: Double? {
        guard let progress, progress.total > 0 else { return nil }
        return min(1, max(0, Double(progress.done) / Double(progress.total)))
    }

    private var helpText: String {
        guard let progress, progress.total > 0 else { return "Response in progress" }
        return "Todos \(progress.done)/\(progress.total)"
    }

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: fraction, total: 1)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.circular)
        .controlSize(.small)
        .frame(width: 14, height: 14)
        .help(helpText)
        .accessibilityLabel(helpText)
        .animation(.easeInOut(duration: 0.2), value: fraction)
    }
}
