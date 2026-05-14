import SwiftUI
import ClarcCore

// MARK: - ChatStatus

/// Per-chat status derived from streaming state, pending permissions, and errors.
public enum ChatStatus: Sendable, Equatable {
    case idle
    case streaming
    case awaitingPermission
    case done
    case error(String)
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
    let onSelect: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = .current
        f.unitsStyle = .abbreviated
        return f
    }()

    private var isActiveStatus: Bool {
        switch status {
        case .streaming, .awaitingPermission, .done, .error: return true
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

            Text(Self.relativeDateFormatter.localizedString(for: summary.updatedAt, relativeTo: Date()))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(ClaudeTheme.textTertiary)
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
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .streaming:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 8, height: 8)
                .help("Response in progress")
        case .awaitingPermission, .done, .error:
            StatusBadgeDot(status: status)
        case .idle:
            EmptyView()
        }
    }
}
