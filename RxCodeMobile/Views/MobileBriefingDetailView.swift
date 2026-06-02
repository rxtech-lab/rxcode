import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync

struct MobileBriefingDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    @Namespace private var glassNamespace
    let groupKey: BriefingGroupKey
    var onOpenSession: (String) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @State private var showingNewThread = false
    @State private var isInitializingGit = false
    @State private var isCreatingPR = false

    // Autopilot context menu (1:1 with the desktop briefing/project menu).
    @State private var autopilotStatus: AutopilotProjectStatus?
    @State private var showingSecretsDownload = false
    @State private var showingReleaseCreate = false
    @State private var autopilotSetupChat: AutopilotSetupChat?
    @State private var autopilotInfo: AutopilotMenuInfo?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                headerCard
                summaryCard
                threadsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("briefing-detail-screen")
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewThread = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                }
                .accessibilityLabel("New Thread")
                .accessibilityIdentifier("briefing-detail-new-thread")
            }

            if showsActionsMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let project, project.gitHubRepo != nil {
                            ProjectAutopilotMenuItems(
                                project: project,
                                status: autopilotStatus,
                                showDownloadSheet: $showingSecretsDownload,
                                showReleaseCreate: $showingReleaseCreate,
                                setupChat: $autopilotSetupChat,
                                info: $autopilotInfo
                            )
                            // Offer "Create PR" for a real branch with no open PR
                            // yet (mirrors the desktop briefing PR button); once a
                            // PR exists the "Open Pull Request" link below covers it.
                            if !isUnknownBranch && !gitHubURLIsPullRequest {
                                Button {
                                    createPullRequest(project: project)
                                } label: {
                                    Label("Create Pull Request", systemImage: "arrow.triangle.pull.request")
                                }
                                .disabled(isCreatingPR)
                            }
                            if gitHubURL != nil { Divider() }
                        }
                        if let gitHubURL {
                            Link(destination: gitHubURL) {
                                Label(
                                    gitHubURLIsPullRequest ? "Open Pull Request" : "Open on GitHub",
                                    systemImage: "arrow.up.forward.square"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .accessibilityLabel("Project actions")
                    .accessibilityIdentifier("briefing-detail-actions")
                }
            }
        }
        .projectAutopilotMenuHost(
            project: project,
            status: $autopilotStatus,
            showDownloadSheet: $showingSecretsDownload,
            showReleaseCreate: $showingReleaseCreate,
            setupChat: $autopilotSetupChat,
            info: $autopilotInfo,
            state: state
        )
        .sheet(isPresented: $showingNewThread) {
            NewThreadSheet(
                projectID: groupKey.projectId,
                preferredBranch: groupKey.branch
            ) { newSessionID in
                onOpenSession(newSessionID)
            }
            .environmentObject(state)
            .mobileSheetPresentation()
        }
        .refreshable {
            await state.refreshSnapshot()
        }
        .onAppear {
            AnalyticsService.shared.log(.briefingDetailOpened, parameters: [
                "project_id": groupKey.projectId.uuidString,
                "branch": groupKey.branch,
            ])
        }
        .mobileAutopilotLoadingDialog(
            isCreatingPR,
            title: "Creating Pull Request…",
            message: "The Mac is pushing the branch and opening the PR."
        )
    }

    private var group: GroupedBriefing? {
        groupBriefings(
            briefings: state.branchBriefings.filter {
                $0.projectId == groupKey.projectId && $0.branch == groupKey.branch
            },
            threads: state.threadSummaries.filter {
                $0.projectId == groupKey.projectId && $0.branch == groupKey.branch
            }
        ).first
    }

    private var projectName: String {
        project?.name ?? "Unknown Project"
    }

    private var project: Project? {
        state.projects.first(where: { $0.id == groupKey.projectId })
    }

    /// Show the ellipsis menu when there's an autopilot-capable repo or a GitHub
    /// link to surface.
    private var showsActionsMenu: Bool {
        project?.gitHubRepo != nil || gitHubURL != nil
    }

    /// GitHub destination for the "Open on GitHub" action. Prefers the pull
    /// request associated with the branch (mirroring the menu bar extra), and
    /// falls back to the repository page when no PR is known.
    private var gitHubURL: URL? {
        if let status = ciStatus, let prNumber = status.prNumber {
            return URL(string: "https://github.com/\(status.owner)/\(status.repo)/pull/\(prNumber)")
        }
        guard let repo = state.projects.first(where: { $0.id == groupKey.projectId })?.gitHubRepo else {
            return nil
        }
        return gitHubWebURL(forOwnerRepo: repo)
    }

    /// True when the GitHub action points at a pull request rather than the repo.
    private var gitHubURLIsPullRequest: Bool {
        ciStatus?.prNumber != nil
    }

    private var isUnknownBranch: Bool {
        groupKey.branch.lowercased() == "unknown"
    }

    private var ciStatus: ProjectCIStatus? {
        guard state.projectBranches[groupKey.projectId] == groupKey.branch else { return nil }
        return state.ciStatusByProject[groupKey.projectId]
    }

    private func initializeGit() {
        guard !isInitializingGit else { return }
        isInitializingGit = true
        Task {
            await state.initProjectGit(projectID: groupKey.projectId)
            await state.refreshSnapshot()
            isInitializingGit = false
        }
    }

    /// Ask the Mac to open a PR for this branch, then open it in the browser.
    /// The Mac pushes the branch, drafts the title/body from the briefing, and
    /// creates the PR; on failure we surface the reason in the info alert.
    private func createPullRequest(project: Project) {
        guard !isCreatingPR else { return }
        isCreatingPR = true
        Task {
            defer { isCreatingPR = false }
            do {
                let url = try await state.requestProjectCreatePullRequest(
                    projectId: project.id,
                    branch: groupKey.branch
                )
                await state.refreshSnapshot()
                openURL(url)
            } catch {
                autopilotInfo = AutopilotMenuInfo(text: error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        HStack(spacing: 14) {
            // Project icon
            ZStack {
                Circle()
                    .fill(accentGradient.opacity(0.15))
                    .frame(width: 52, height: 52)
                
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accentGradient)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(projectName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Chips wrap to the next line when the branch name is long
                // instead of overflowing the card width.
                BriefingFlowLayout(spacing: 12) {
                    // Branch chip — falls back to an Init Git action when the
                    // desktop hasn't initialized a repo (branch is "unknown").
                    if isUnknownBranch {
                        Button {
                            initializeGit()
                        } label: {
                            HStack(spacing: 5) {
                                if isInitializingGit {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                Text(isInitializingGit ? "Initializing…" : "Initialize Git")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isInitializingGit)
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .medium))
                            Text(groupKey.branch)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    }

                    if let ciStatus {
                        MobileCIStatusChip(status: ciStatus, linksFailingRun: true)
                    }

                    // Updated time
                    if let updatedAt = group?.updatedAt {
                        Text(updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - Summary Card

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentGradient)
                
                Text("Summary")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            if let summary = group?.briefing?.briefing, !summary.isEmpty {
                ChatTextContentView(
                    markdown: summary,
                    size: 15,
                    color: .primary,
                    lineSpacing: 4
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "text.justify.leading")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No summary yet")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("A summary will appear after threads complete")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - Threads Section

    @ViewBuilder
    private var threadsSection: some View {
        let threads = group?.threads ?? []
        
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentGradient)
                
                Text("Threads")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                
                if !threads.isEmpty {
                    Text("\(threads.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.leading, 4)

            if threads.isEmpty {
                emptyThreadsCard
            } else {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(threads) { thread in
                            NavigationLink(value: thread.sessionId) {
                                MobileBriefingThreadCard(
                                    thread: thread,
                                    isStreaming: isThreadStreaming(thread.sessionId),
                                    namespace: glassNamespace
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("briefing-thread-row-\(thread.sessionId)")
                        }
                    }
                }
            }
        }
    }

    private var emptyThreadsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("No threads yet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Start a conversation from your Mac")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func isThreadStreaming(_ sessionId: String) -> Bool {
        state.sessions.first(where: { $0.id == sessionId })?.isStreaming ?? false
    }

    // MARK: - Accent Gradient

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.6, blue: 0.4),
                Color(red: 0.85, green: 0.5, blue: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Thread Card

struct MobileBriefingThreadCard: View {
    let thread: MobileThreadSummary
    let isStreaming: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Thread icon
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
                
                Image(systemName: "text.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                if !thread.summary.isEmpty {
                    ChatTextContentView(
                        markdown: thread.summary,
                        size: 13,
                        color: .secondary,
                        lineSpacing: 2,
                        maximumNumberOfLines: 3
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                
                if isStreaming {
                    MobileBriefingThreadLoadingBadge()
                } else {
                    Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .glassEffectID(thread.id, in: namespace)
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let title = thread.title.isEmpty ? "Untitled" : thread.title
        if isStreaming {
            return "\(title), response in progress"
        }
        return title
    }
}

private struct MobileBriefingThreadLoadingBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)

            Text("Response in progress")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.tint.opacity(0.12), in: Capsule())
    }
}
