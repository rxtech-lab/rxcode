import RxCodeCore
import RxCodeSync
import SwiftUI

extension MobileChatView {
    // MARK: - Thread actions toolbar

    @ToolbarContentBuilder
    var threadActionsToolbar: some ToolbarContent {
        if threadExists {
            ToolbarItem(placement: .principal) {
                navigationTitleView
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingBrowser = true
                    } label: {
                        Label("Open in Browser", systemImage: "globe")
                    }
                    Button {
                        showingRunProfiles = true
                    } label: {
                        Label("Run Profiles", systemImage: "play.rectangle")
                    }
                    .disabled(currentProjectID == nil)
                    Button {
                        showingChanges = true
                    } label: {
                        Label("View Changes", systemImage: "plus.forwardslash.minus")
                    }
                    Divider()
                    Button {
                        showingRenameSheet = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        showingArchiveConfirm = true
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Thread actions")
            }
        }
    }

    /// Tappable navigation-title view. Tapping always opens the todo + summary
    /// sheet so the thread summary stays reachable. When the thread has todos
    /// it also shows a progress indicator; otherwise a subtle chevron hints
    /// that the title is interactive. Mirrors the desktop's todo progress pill.
    @ViewBuilder
    var navigationTitleView: some View {
        let todos = self.todos
        Button {
            showingTodoSheet = true
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let todos, !todos.isEmpty {
                    let done = todos.filter { $0.status == .completed }.count
                    let inProgress = todos.contains { $0.status == .inProgress }
                    MobileTodoProgressIndicator(
                        done: done,
                        total: todos.count,
                        inProgress: inProgress
                    )
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(navigationTitleAccessibilityLabel)
        .accessibilityHint("Opens todos and thread summary")
    }

    var navigationTitleAccessibilityLabel: String {
        guard let todos, !todos.isEmpty else {
            return "\(title). Tap to view thread summary."
        }
        let done = todos.filter { $0.status == .completed }.count
        return "\(title). Todos, \(done) of \(todos.count) complete. Tap to view todos and thread summary."
    }

    /// A real, persisted thread the desktop can act on — excludes drafts.
    var threadExists: Bool {
        !MobileDraftSessionID.isDraft(sessionID)
            && state.sessions.contains(where: { $0.id == sessionID })
    }

    func performArchive() {
        Task { await state.archiveThread(sessionID: sessionID) }
        onClose()
    }

    func performDelete() {
        Task { await state.deleteThread(sessionID: sessionID) }
        onClose()
    }

    // MARK: - Queued preview pill

    var queuedPreviewPill: some View {
        Button {
            showingQueueSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(queuedMessages.count) queued")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let first = queuedMessages.first {
                        Text(first.text)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(queuedMessages.count) queued messages. Tap to view all.")
    }

    // MARK: - Question queue banner

    /// Compact pill shown directly above the input bar whenever the agent has
    /// `AskUserQuestion` calls awaiting an answer. Tapping it opens the question
    /// sheet for the first queued request — mirrors the desktop banner.
    var questionQueueBanner: some View {
        Button {
            presentedQuestion = sessionQuestions.first
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)

                Text(questionBannerText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer(minLength: 8)

                Text("Answer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(ClaudeTheme.accent, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ClaudeTheme.accentSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ClaudeTheme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(questionBannerText). Tap to answer.")
    }

    var questionBannerText: String {
        let count = sessionQuestions.count
        return count == 1 ? "1 question pending" : "\(count) questions pending"
    }

    // MARK: - Plan review banner

    /// Compact pill above the input bar shown whenever the agent has produced a
    /// plan awaiting a decision. Tapping it opens the shared `PlanSheetView` —
    /// the same review/accept/modify component the desktop uses.
    var planBanner: some View {
        Button {
            presentedPlan = pendingPlans.first
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)

                Text(planBannerText)
                    .font(.system(size: 13, weight: .medium))

                Spacer(minLength: 8)

                Text("Review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(ClaudeTheme.accent, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(ClaudeTheme.accent).interactive(), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(planBannerText). Tap to review.")
    }

    var planBannerText: String {
        let count = pendingPlans.count
        return count == 1 ? "Plan ready to review" : "\(count) plans ready to review"
    }
}
