import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct CodingPlanWorkspace: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let room: CodingPlanRoom
    let returnToChat: (() -> Void)?
    @State private var compactPane = 1
    @State private var selectedVersionID: UUID?
    @State private var newestArrival: UUID?
    @State private var revision: CodingPlan.Version?
    @State private var implementing: CodingPlan.Version?
    @State private var showingReviewers = false
    @State private var newReviewer: CodingPlan.Reviewer?
    @State private var debateError: String?
    @State private var messageDraft = ""
    @State private var composerHeight: CGFloat = 0
    @State private var debatePosition = ScrollPosition(idType: String.self)
    @State private var debateFraction: CGFloat = 0.5
    @State private var radio = CodingPlanRadioPlayer()
    @GestureState private var dividerTranslation: CGFloat = 0

    private var plan: CodingPlan { room.plan }
    private var cwd: String {
        appState.threadStore.fetch(id: window.currentSessionId ?? "")?.worktreePath ?? window.selectedProject?.path ?? ""
    }
    private var version: CodingPlan.Version? {
        if let id = selectedVersionID ?? plan.approvedVersionID { return plan.versions.first { $0.id == id } }
        return plan.versions.last
    }
    private var followsLive: Bool { selectedVersionID == nil && room.runID != nil }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if geometry.size.width >= 510 {
                    splitWorkspace(width: geometry.size.width)
                } else {
                    VStack(spacing: 0) {
                        Picker("Planning workspace", selection: $compactPane) {
                            Text("Debate").tag(0)
                            Text("Plan").tag(1)
                        }
                        .pickerStyle(.segmented).labelsHidden().padding(8)
                        if compactPane == 0 {
                            debatePane
                        } else {
                            documentPane
                                .safeAreaInset(edge: .bottom, spacing: 0) { composerBar }
                        }
                    }
                }
            }
            Divider()
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClaudeTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coding-plan-workspace")
        .overlay { if room.isHandingOff { PlanningProgress(label: "Starting implementation…") } }
        .onChange(of: plan.lastError, initial: true) { _, error in debateError = error }
        .planningError($debateError)
        .sheet(isPresented: $showingReviewers) {
            CodingPlanReviewersSheet(room: room, addReviewer: addReviewer)
        }
        .sheet(item: $newReviewer) { reviewer in
            CodingPlanReviewerSheet(reviewer: reviewer, title: "Add Reviewer", save: addReviewer)
        }
        .sheet(item: $revision) { version in
            CodingPlanRevisionSheet(version: version) { text, askHost, comment in
                try appState.reviseCodingPlan(room, base: version.id, text: text, askHost: askHost, comment: comment, cwd: cwd)
                selectedVersionID = nil
            }
        }
        .sheet(item: $implementing) { chosen in
            CodingPlanImplementationSheet(model: plan.configuration.planner,
                versionNumber: (plan.versions.firstIndex { $0.id == chosen.id } ?? 0) + 1) { model, effort in
                implementing = nil
                Task { await appState.implementCodingPlan(room, versionID: chosen.id, model: model, effort: effort, in: window) }
            }
        }
        .onChange(of: plan.versions.last?.id) { _, id in newestArrival = id }
        .onChange(of: room.dispatch?.id) {
            if let update = room.dispatch { radio.receive(update.text) }
        }
        .onChange(of: plan.id) { radio.stop() }
        .onDisappear { radio.stop() }
    }

    private func splitWorkspace(width: CGFloat) -> some View {
        let dividerWidth: CGFloat = 7
        let maximum = width - dividerWidth - 260
        let start = min(max(width * debateFraction, 180), maximum)
        func debateWidth(_ translation: CGFloat) -> CGFloat {
            min(max(start + translation, 180), maximum)
        }
        return HStack(spacing: 0) {
            debatePane.frame(width: debateWidth(dividerTranslation))
            Color.clear
                .frame(width: dividerWidth)
                .overlay { Divider() }
                .contentShape(Rectangle())
                .pointerStyle(.columnResize)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dividerTranslation) { value, translation, transaction in
                        translation = value.translation.width
                        transaction.animation = nil
                    }
                    .onEnded { debateFraction = debateWidth($0.translation.width) / width })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Debate room width")
                .accessibilityValue("\(Int(100 * start / width)) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: debateFraction = debateWidth(24) / width
                    case .decrement: debateFraction = debateWidth(-24) / width
                    @unknown default: break
                    }
                }
            documentPane.frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(width: width)
    }

    private var debatePane: some View {
        let turnStart = room.runID == nil ? plan.contributions.endIndex : room.turnStartIndex
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label("Debate Room", systemImage: "bubble.left.and.bubble.right").font(.headline).lineLimit(1)
                    .layoutPriority(1)
                debateHeaderControls
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 46)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    contribution(role: "You", model: nil) {
                        CodingPlanUserMessage(text: plan.goal)
                    }
                    ForEach(plan.contributions.prefix(turnStart)) { recordedContribution($0) }
                    if let step = plan.nextStep, room.runID != nil {
                        liveContribution(step).id("active-speaker")
                    }
                    ForEach(plan.contributions.dropFirst(turnStart)) { recordedContribution($0) }
                }
                .scrollTargetLayout()
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, composerHeight)
            }
            .scrollPosition($debatePosition)
            .accessibilityIdentifier("coding-plan-messages")
            .overlay(alignment: .bottom) {
                composerBar
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { composerHeight = $0 }
            }
            .onChange(of: plan.nextStep) { _, step in
                if step != nil {
                    withAnimation(reduceMotion ? nil : .easeOut) { debatePosition.scrollTo(id: "active-speaker", anchor: .top) }
                }
            }
            .onChange(of: plan.contributions.last?.id) {
                if let last = plan.contributions.last, last.isUserMessage || plan.nextStep == nil {
                    withAnimation(reduceMotion ? nil : .easeOut) { debatePosition.scrollTo(edge: .bottom) }
                }
            }
        }
        .background(ClaudeTheme.surfaceSecondary.opacity(0.55))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coding-plan-debate")
    }

    private var debateHeaderControls: some View {
        ViewThatFits(in: .horizontal) {
            debateHeaderButtons.fixedSize()
            debateHeaderButtons.labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .disabled(room.isHandingOff)
    }

    private var debateHeaderButtons: some View {
        HStack(spacing: 6) {
            CodingPlanRadioControl(room: room, player: radio).id(plan.id)
            reviewerButtons
        }
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            PermissionQueueBanner(horizontalInset: 0)
                .lineLimit(1)
                .accessibilityIdentifier("coding-plan-pending-question")
            if plan.approvedVersionID == nil {
                messageComposer
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 12)
    }

    private var reviewerButtons: some View {
        HStack(spacing: 6) {
            Button("Reviewers", systemImage: "person.2") { showingReviewers = true }
                .accessibilityIdentifier("coding-plan-reviewers")
                .help("View plan reviewers")
            if room.canAddReviewer {
                Button("Add Reviewer…", systemImage: "person.badge.plus") {
                    newReviewer = .init(model: plan.configuration.planner, prompt: "")
                }
                .accessibilityIdentifier("coding-plan-composer-add-reviewer")
                .help("Add a reviewer to this plan")
            }
        }
    }

    private func addReviewer(_ reviewer: CodingPlan.Reviewer) throws {
        try appState.addCodingPlanReviewer(reviewer, to: room, cwd: cwd)
    }

    private var messageComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MarkdownDescriptionEditor(
                text: $messageDraft,
                placeholder: String(localized: "Message the debate…"),
                isDisabled: room.isHandingOff,
                identifierPrefix: "coding-plan-message",
                editorIdentifier: "coding-plan-message",
                layout: .composer(onSubmit: sendMessage)
            )
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ClaudeTheme.accent)
            .disabled(messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("coding-plan-send")
            .help("Send to the next speaker")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: ClaudeTheme.cornerRadiusPill))
        .disabled(room.isHandingOff)
    }

    private func sendMessage() {
        do {
            try appState.sendCodingPlanMessage(messageDraft, to: room, cwd: cwd)
            messageDraft = ""
        } catch {
            debateError = error.localizedDescription
        }
    }

    private func recordedContribution(_ message: CodingPlan.Contribution) -> some View {
        let index = message.versionID.flatMap { id in plan.versions.firstIndex { $0.id == id } }
        return contribution(role: message.role, model: message.model, review: message.isReview, tools: message.toolCalls ?? []) {
            if message.isReview {
                reviewFeedback(CodingPlanReview(message.text), live: false, applied: index.map { plan.versions[$0].edits } ?? [])
            } else if index == nil {
                if message.isUserMessage {
                    CodingPlanUserMessage(text: message.debateText)
                } else {
                    agentFeedback(message.text, expandsHorizontally: false)
                }
            }
            if index != nil, !message.isReview, let briefing = message.briefing { agentFeedback(briefing) }
            if let index { planChip(versionAt: index, fromUser: message.model == nil) }
        }
    }

    private func liveContribution(_ step: CodingPlan.Step) -> some View {
        let speaker = plan.speaker(for: step)
        return contribution(role: speaker.role, model: speaker.model, review: step.proposesEdits,
                            tools: room.liveTurn.toolCalls, live: true) {
            if step.writesPlan {
                if let briefing = room.liveBroadcast.briefing { agentFeedback(briefing) }
                planChip(versionAt: nil)
            } else if step.proposesEdits {
                let review = CodingPlanReview(room.liveText)
                let edits = review.applying(to: plan.versions.last?.markdown ?? "").edits
                reviewFeedback(review, live: true, applied: edits)
                if !edits.isEmpty { planChip(versionAt: nil) }
            } else if !room.liveText.isEmpty {
                agentFeedback(room.liveText, live: true)
            }
        }
    }

    @ViewBuilder private func reviewFeedback(_ review: CodingPlanReview, live: Bool, applied: [CodingPlanReview.Edit]) -> some View {
        agentFeedback(review.commentary, live: live)
        // Suggestions without an exact match stay in the debate for the host to consider.
        let unmatched = review.edits.filter { proposal in
            !applied.contains { $0.original == proposal.original && $0.replacement == proposal.replacement }
        }
        ForEach(Array(unmatched.enumerated()), id: \.offset) { _, edit in
            TrackedPlanMarkdown(markdown: edit.replacement,
                                edits: [.init(original: edit.original, replacement: edit.replacement, offset: 0, comment: edit.comment)],
                                animateEdits: live, compact: true)
        }
    }

    @ViewBuilder private func agentFeedback(_ text: String, live: Bool = false, expandsHorizontally: Bool = true) -> some View {
        let markdown = CodingPlanReview.feedbackMarkdown(text, streaming: live)
        if !markdown.isEmpty {
            MarkdownContentView(text: markdown, style: .rxCodeCompact, fadeNewText: live && !reduceMotion,
                                expandsHorizontally: expandsHorizontally)
        }
    }

    private func planChip(versionAt index: Int?, fromUser: Bool = false) -> some View {
        let item = index.map { plan.versions[$0] }
        let title = if let index, let item { "v\(index + 1) · \(item.title)" } else { "Live plan" }
        let selected = item.map { !followsLive && version?.id == $0.id } ?? followsLive
        let tint = fromUser ? ClaudeTheme.userBubbleText : ClaudeTheme.accent
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                selectedVersionID = item?.id
                compactPane = 1
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .accessibilityHidden(true)
                Text(title).lineLimit(1)
                Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(fromUser ? ClaudeTheme.userBubbleText : ClaudeTheme.accentText)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(tint.opacity(selected ? 0.18 : 0.07), in: Capsule())
            .overlay { Capsule().strokeBorder(tint.opacity(selected ? 0.65 : 0.28), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(title) in the plan pane")
        .accessibilityHint("Opens this version in the plan pane")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(index.map { "coding-plan-chip-\($0 + 1)" } ?? "coding-plan-chip-live")
    }

    private func contribution<Content: View>(role: String, model: AgentModel?, review: Bool = false,
                                              tools: [ToolCall] = [], live: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model == nil ? "person.circle" : review ? "text.bubble" : "pencil.and.outline")
                    .foregroundStyle(model == nil ? ClaudeTheme.userBubbleText : ClaudeTheme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(role).font(.subheadline.weight(.semibold))
                            .foregroundStyle(model == nil ? ClaudeTheme.userBubbleText : ClaudeTheme.textPrimary)
                        if live {
                            AnimatedDotsView()
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(role) is responding")
                                .accessibilityIdentifier("coding-plan-streaming-dots")
                        }
                    }
                    if let model {
                        Text(appState.modelDisplayLabel(model.id, provider: model.provider))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !tools.isEmpty { ToolActivityGroupView(tools: tools, isStreaming: live) }
            content()
        }
        .bubbleStyle(model == nil ? .user : .assistant)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model == nil ? "coding-plan-user-bubble" : "coding-plan-agent-bubble")
        .padding(model == nil ? .leading : .trailing, 12)
        .frame(maxWidth: .infinity, alignment: model == nil ? .trailing : .leading)
    }

    private var documentPane: some View {
        let page = documentPage
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Implementation Plan", systemImage: "doc.text").font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                if !page.edits.isEmpty {
                    Text("^[\(page.edits.count) change](inflect: true)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1)
                        .help("Dotted underlines mark changes. Click one to see the original text and comments.")
                        .accessibilityIdentifier("coding-plan-change-count")
                }
                if !plan.versions.isEmpty { versionsMenu }
            }
            .padding(.horizontal, 16).frame(height: 46)
            Divider()
            ZStack(alignment: .topLeading) {
                Group {
                    if page.id == .waiting {
                        ContentUnavailableView("Awaiting the Draft", systemImage: "doc.text", description: Text("The planner’s response will appear here."))
                    } else {
                        ScrollView {
                            Group {
                                if case .writing = page.id {
                                    MarkdownContentView(text: page.markdown, showsTrailingCursor: true, fadeNewText: !reduceMotion)
                                } else {
                                    TrackedPlanMarkdown(markdown: page.markdown, edits: page.edits, reviewer: page.reviewer,
                                        animateEdits: page.animateEdits, addComment: commentAction(for: page.versionID))
                                }
                            }
                            .frame(maxWidth: 820, alignment: .leading)
                            .padding(22)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(page.id)
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: page.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coding-plan-document")
    }

    private struct DocumentPage {
        enum ID: Hashable {
            case waiting, writing(UUID, CodingPlan.Step), proposal(UUID), version(UUID)
        }
        let id: ID
        let markdown: String
        var edits: [CodingPlanReview.Edit] = []
        var reviewer: String?
        var versionID: UUID?
        var animateEdits = false
    }

    private var documentPage: DocumentPage {
        if followsLive, let run = room.runID, let step = plan.nextStep, !room.liveText.isEmpty {
            if step.proposesEdits, let base = plan.versions.last {
                let proposal = CodingPlanReview(room.liveText).applying(to: base.markdown)
                if !proposal.edits.isEmpty {
                    return DocumentPage(id: .proposal(base.id), markdown: proposal.markdown, edits: proposal.edits,
                                        reviewer: plan.speaker(for: step).role, animateEdits: true)
                }
            } else if step.writesPlan {
                return DocumentPage(id: .writing(run, step), markdown: room.liveText)
            }
        }
        guard let version else { return DocumentPage(id: .waiting, markdown: "") }
        let author = plan.contributions.first { $0.versionID == version.id }
        let reviewer = author?.model != nil ? author?.role : nil
        var id = DocumentPage.ID.version(version.id)
        if author?.isReview == true, let index = plan.versions.firstIndex(where: { $0.id == version.id }), index > 0 {
            id = .proposal(plan.versions[index - 1].id)
        }
        return DocumentPage(id: id, markdown: version.markdown, edits: version.edits, reviewer: reviewer,
                            versionID: version.id, animateEdits: selectedVersionID == nil && newestArrival == version.id)
    }

    private func commentAction(for versionID: UUID?) -> ((Int, String) throws -> Void)? {
        guard let versionID, plan.approvedVersionID == nil else { return nil }
        return { index, text in try appState.addCodingPlanComment(text, to: index, in: versionID, room: room) }
    }

    private var versionsMenu: some View {
        Menu {
            if room.runID != nil { Button("Follow Live Plan") { selectedVersionID = nil }; Divider() }
            ForEach(Array(plan.versions.enumerated().reversed()), id: \.element.id) { index, item in
                Button {
                    selectedVersionID = item.id
                } label: {
                    let label = "v\(index + 1) · \(item.title)"
                    if version?.id == item.id { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            if followsLive { Text("Live") }
            else if let index = plan.versions.firstIndex(where: { $0.id == version?.id }) { Text("v\(index + 1)") }
        }
        .fixedSize()
        .help("Plan versions")
        .accessibilityIdentifier("coding-plan-versions")
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let returnToChat {
                Button { returnToChat() } label: { Label("Implementation Chat", systemImage: "chevron.left") }
            }
            Spacer(minLength: 0)
            if room.runID != nil {
                Button("Stop Debate", systemImage: "stop.fill") { room.stop() }
            } else if plan.nextStep != nil {
                Button("Resume Debate", systemImage: "play.fill") { appState.resumeCodingPlan(room, cwd: cwd) }
                    .accessibilityIdentifier("coding-plan-resume")
            } else if let version {
                if plan.approvedVersionID == nil {
                    Button("Revise…", systemImage: "pencil") { revision = version }
                        .disabled(version.id != plan.versions.last?.id)
                        .accessibilityIdentifier("coding-plan-revise")
                } else if returnToChat == nil {
                    implementationLinks
                }
                Button("Implement…", systemImage: "play.fill") { implementing = version }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("coding-plan-implement")
            }
        }
        .disabled(room.isHandingOff)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private var implementationLinks: some View {
        let runs = appState.threadStore.implementationThreads(for: plan.id)
        if runs.count == 1, let run = runs.first {
            Button("Open Implementation") { open(run) }
        } else if !runs.isEmpty {
            Menu("Implementations") {
                ForEach(runs) { run in
                    Button("\(run.title) · \(appState.modelDisplayLabel(run.model ?? "", provider: run.agentProvider))") { open(run) }
                }
            }
            .fixedSize()
        }
    }

    private func open(_ run: ChatSession.Summary) {
        appState.selectSession(id: run.id, inChatTab: window.generalRoute == .chat, in: window)
    }
}

private struct CodingPlanUserMessage: View {
    let text: String
    @State private var markdown = ""
    @State private var attachments: [Attachment] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty { AttachmentPreviewStrip(attachments: attachments) }
            if !markdown.isEmpty {
                MarkdownContentView(text: markdown, style: .rxCodeChatUser, expandsHorizontally: false)
            }
        }
        .rxCodeAttachmentPreviews()
        .onChange(of: text, initial: true) { _, text in
            var chips = DescriptionAttachmentChips()
            var display = chips.display(for: text)
            attachments = chips.attachments(in: display)
            for item in attachments { display = chips.removing(item, from: display) }
            markdown = chips.markdown(for: display).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private struct CodingPlanImplementationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State var model: AgentModel
    @State private var effort: String?
    let versionNumber: Int
    let implement: (AgentModel, String?) -> Void

    init(model: AgentModel, versionNumber: Int, implement: @escaping (AgentModel, String?) -> Void) {
        _model = State(initialValue: model)
        self.versionNumber = versionNumber
        self.implement = implement
    }

    var body: some View {
        let levels = appState.reasoningLevels(for: model.provider, model: model.id)
        NavigationStack {
            Form {
                PlanModelPicker(title: "Model", model: $model)
                    .accessibilityIdentifier("coding-plan-implementation-model")
                if !levels.isEmpty {
                    TaskThinkingLevelPicker(levels: levels, defaultTitle: appState.defaultEffortTitle(for: model.provider, model: model.id),
                                            effort: $effort)
                        .accessibilityIdentifier("coding-plan-implementation-effort")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Implement version \(versionNumber)")
            .navigationSubtitle("Start a fresh chat with this plan.")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Implementation") { implement(model, levels.first { $0.id == effort }?.id) }
                        .accessibilityIdentifier("coding-plan-confirm-implementation")
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 240, idealHeight: 280, maxHeight: .infinity)
        .task(id: model.key) {
            await appState.loadReasoningLevels(for: model.provider)
            guard !Task.isCancelled, let effort,
                  !appState.reasoningLevels(for: model.provider, model: model.id).contains(where: { $0.id == effort }) else { return }
            self.effort = nil
        }
    }
}

private struct CodingPlanRevisionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let version: CodingPlan.Version
    let save: (String, Bool, String) throws -> Void
    @State private var askHost = false
    @State private var edited: String
    @State private var feedback = ""
    @State private var comment = ""
    @State private var error: String?

    init(version: CodingPlan.Version, save: @escaping (String, Bool, String) throws -> Void) {
        self.version = version
        self.save = save
        _edited = State(initialValue: version.markdown)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Revision", selection: $askHost) {
                    Text("Edit Plan").tag(false)
                    Text("Ask Host").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if askHost {
                    ScrollView {
                        MarkdownDescriptionEditor(
                            text: $feedback,
                            placeholder: String(localized: "Describe the requested changes…"),
                            title: "What should the host change?",
                            identifierPrefix: "coding-plan-revision-request",
                            editorIdentifier: "coding-plan-revision-text"
                        )
                    }
                } else {
                    Text("Implementation plan").font(.headline)
                    TextEditor(text: $edited)
                        .font(.system(.body, design: .monospaced))
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("coding-plan-revision-text")
                    TextField("Comment (optional)", text: $comment, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("coding-plan-revision-comment")
                }
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Revise Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(askHost ? "Request Revision" : "Save Version") {
                        do { try save(askHost ? feedback : edited, askHost, comment); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(askHost ? feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              : edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || edited == version.markdown)
                }
            }
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 440, idealHeight: 560, maxHeight: .infinity)
        .planningError($error)
    }
}
