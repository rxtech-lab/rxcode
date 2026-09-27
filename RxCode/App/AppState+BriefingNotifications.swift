import Foundation
import RxCodeCore
import UniformTypeIdentifiers
import os

/// Sends published document briefings to the user through the Autopilot
/// notification service (email for now).
///
/// When an agent publishes a briefing, RxCode waits for that agent's run to
/// finish, then — unless the run already sent a notification itself (e.g. a
/// scheduled task told it to) — hands the briefing, the project's
/// notification configuration and the source chat to the general AI task
/// agent, which decides whether it is worth sending. Local images are
/// converted to WebP, uploaded as Autopilot attachments and embedded in
/// place. Every send, failure and skip is recorded in `notificationStore`.
extension AppState {

    // MARK: - Settings

    func loadBriefingNotificationSettings() async {
        let settings = await notificationStore.settings()
        if settings != briefingNotificationSettings {
            briefingNotificationSettings = settings
        }
    }

    func updateBriefingNotificationSettings(_ update: (inout BriefingNotificationSettings) -> Void) {
        var settings = briefingNotificationSettings
        update(&settings)
        guard settings != briefingNotificationSettings else { return }
        briefingNotificationSettings = settings
        Task { [notificationStore, logger] in
            do {
                try await notificationStore.saveSettings(settings)
            } catch {
                logger.error("[Notifications] failed to save settings: \(error.localizedDescription)")
            }
        }
    }

    func notificationHistory() async -> [NotificationRecord] {
        await notificationStore.history()
    }

    func clearNotificationHistory() async throws {
        try await notificationStore.clearHistory()
    }

    // MARK: - Publish hook

    /// Called after an agent publishes `briefing`. Returns immediately; the
    /// decision runs once the publishing agent's turn has finished.
    func briefingWasPublished(_ briefing: BriefingDocument, sessionKey: String?) {
        guard briefing.isPublished,
              briefingNotificationSettings.mode(for: briefing.projectId) != .never,
              !briefingNotificationsInFlight.contains(briefing.id)
        else { return }
        briefingNotificationsInFlight.insert(briefing.id)
        Task { [weak self] in
            await self?.processBriefingNotification(briefingId: briefing.id, sessionKey: sessionKey)
            self?.briefingNotificationsInFlight.remove(briefing.id)
        }
    }

    private func processBriefingNotification(briefingId: UUID, sessionKey: String?) async {
        let sessionKeys = notificationSessionKeys(sessionKey)
        // A notification sent by the run (e.g. a scheduled task that emails its
        // report) often comes after the publish call, so wait for it to end.
        await waitForSessionsToFinish(sessionKeys)

        guard isSignedIn,
              let briefing = try? await briefingStore.load(briefingId), briefing.isPublished
        else { return }
        let settings = briefingNotificationSettings
        let mode = settings.mode(for: briefing.projectId)
        guard mode != .never, !(await notificationStore.hasSent(briefingId: briefing.id)) else { return }

        if scheduledRunNotification(forSessions: sessionKeys) != nil {
            await recordNotification(NotificationRecord(
                source: .briefing, status: .skipped, subject: briefing.title,
                briefingId: briefing.id, projectId: briefing.projectId, sessionKey: sessionKey,
                reason: String(localized: "The scheduled task handles its own notification.")
            ))
            return
        }
        let runStartedAt = runStartDate(for: sessionKeys) ?? briefing.createdAt.addingTimeInterval(-3600)
        if await notificationStore.hasSent(fromSessions: sessionKeys, since: runStartedAt) {
            await recordNotification(NotificationRecord(
                source: .briefing, status: .skipped, subject: briefing.title,
                briefingId: briefing.id, projectId: briefing.projectId, sessionKey: sessionKey,
                reason: String(localized: "The agent run already sent a notification.")
            ))
            return
        }

        let content = await briefingDocumentContent(briefing)
        let decision: BriefingNotificationDecision
        if mode == .always {
            decision = BriefingNotificationDecision(
                shouldSend: true, reason: String(localized: "This project always sends briefings.")
            )
        } else {
            let context = await notificationDecisionContext(
                briefing: briefing, content: content, mode: mode,
                recipient: settings.recipient, sessionKey: sessionKey, sessionKeys: sessionKeys
            )
            guard let raw = await runTaskAgentCompletion(
                prompt: BriefingNotificationDecision.prompt(for: context),
                projectId: briefing.projectId,
                verbatim: true
            ), let parsed = BriefingNotificationDecision.parse(raw) else {
                logger.warning("[Notifications] no usable decision for briefing \(briefing.id.uuidString)")
                await recordNotification(NotificationRecord(
                    source: .briefing, status: .skipped, subject: briefing.title,
                    briefingId: briefing.id, projectId: briefing.projectId, sessionKey: sessionKey,
                    reason: String(localized: "The general AI task agent didn't return a decision.")
                ))
                return
            }
            decision = parsed
        }

        guard decision.shouldSend else {
            await recordNotification(NotificationRecord(
                source: .briefing, status: .skipped, subject: decision.subject ?? briefing.title,
                briefingId: briefing.id, projectId: briefing.projectId, sessionKey: sessionKey,
                reason: decision.reason
            ))
            return
        }
        // The decision can take a while; re-check nothing was sent meanwhile.
        guard !(await notificationStore.hasSent(briefingId: briefing.id)),
              !(await notificationStore.hasSent(fromSessions: sessionKeys, since: runStartedAt))
        else { return }

        _ = await sendNotification(
            subject: decision.subject ?? briefing.title,
            body: content,
            format: briefing.format,
            imageBaseURL: briefingStore.folderURL(for: briefing.id),
            recipient: settings.recipient,
            source: .briefing,
            briefing: briefing,
            sessionKey: sessionKey,
            reason: decision.reason
        )
    }

    // MARK: - Sending

    /// Sends `briefing` as a notification because the user asked to, from its
    /// card. Unlike the automatic path, it doesn't skip briefings already sent.
    func sendBriefingNotification(_ briefing: BriefingDocument, subject: String, recipient: String?) async -> NotificationRecord {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return await sendNotification(
            subject: trimmed.isEmpty ? briefing.title : trimmed,
            body: await briefingDocumentContent(briefing),
            format: briefing.format,
            imageBaseURL: briefingStore.folderURL(for: briefing.id),
            recipient: recipient,
            source: .user,
            briefing: briefing,
            sessionKey: nil
        )
    }

    /// Uploads the body's local images as WebP attachments, sends the
    /// notification through Autopilot and records the outcome locally.
    /// Returns the recorded entry.
    @discardableResult
    func sendNotification(
        subject rawSubject: String,
        body rawBody: String,
        format: BriefingContentFormat?,
        imageBaseURL: URL,
        recipient: String?,
        source: NotificationRecord.Source,
        briefing: BriefingDocument? = nil,
        projectId: UUID? = nil,
        sessionKey: String?,
        reason: String? = nil
    ) async -> NotificationRecord {
        let subject = String(rawSubject.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(SendAutopilotNotificationRequest.maxSubjectLength))
        let projectId = briefing?.projectId ?? projectId
        func record(_ status: NotificationRecord.Status, remoteId: String? = nil, error: String? = nil) -> NotificationRecord {
            NotificationRecord(
                source: source, status: status, remoteId: remoteId, recipient: recipient,
                subject: subject, briefingId: briefing?.id, projectId: projectId,
                sessionKey: sessionKey, reason: reason, errorMessage: error
            )
        }

        var body = rawBody
        var attachmentIds: [String] = []
        if let format {
            let references = NotificationBodyImages.references(in: body, format: format, baseURL: imageBaseURL)
            let uploaded = await uploadNotificationImages(references.map(\.fileURL))
            attachmentIds = Array(uploaded.values)
            body = NotificationBodyImages.replacing(references, in: body, attachmentIds: uploaded)
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = subject
        }
        if body.count > SendAutopilotNotificationRequest.maxBodyLength {
            body = String(body.prefix(SendAutopilotNotificationRequest.maxBodyLength - 20)) + "\n\n…"
        }

        let request = SendAutopilotNotificationRequest(
            recipient: recipient,
            subject: subject.isEmpty ? String(localized: "Briefing") : subject,
            body: body,
            format: format.map { $0 == .html ? .html : .markdown } ?? .text,
            attachments: attachmentIds.isEmpty ? nil : attachmentIds.map { AutopilotAttachmentRef(id: $0, disposition: .embedded) }
        )
        let result: NotificationRecord
        do {
            let sent = try await autopilotNotifications.send(request)
            result = record(sent.status == "failed" ? .failed : .sent, remoteId: sent.id, error: sent.error)
        } catch {
            logger.error("[Notifications] send failed: \(error.localizedDescription)")
            for id in attachmentIds {
                try? await autopilotNotifications.deleteAttachment(id: id)
            }
            result = record(.failed, error: error.localizedDescription)
        }
        await recordNotification(result)
        return result
    }

    /// Uploads each image once as WebP (or as-is when it can't be converted),
    /// within Autopilot's per-notification count and size limits. Returns the
    /// attachment id for every uploaded file; the rest fall back to alt text.
    private func uploadNotificationImages(_ urls: [URL]) async -> [URL: String] {
        var uploaded: [URL: String] = [:]
        var totalBytes = 0
        for url in urls where uploaded[url] == nil {
            guard uploaded.count < AutopilotAttachmentLimits.maxCount else { break }
            let prepared = await Task.detached(priority: .utility) { () -> (Data, String, String)? in
                let base = url.deletingPathExtension().lastPathComponent
                if let webp = WebPEncoder.encode(fileAt: url) {
                    return (webp, "\(base).webp", "image/webp")
                }
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return (data, url.lastPathComponent, mime)
            }.value
            guard let (data, filename, contentType) = prepared,
                  totalBytes + data.count <= AutopilotAttachmentLimits.maxTotalBytes
            else { continue }
            do {
                uploaded[url] = try await autopilotNotifications.uploadAttachment(
                    data: data, filename: filename, contentType: contentType
                )
                totalBytes += data.count
            } catch {
                logger.error("[Notifications] image upload failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return uploaded
    }

    func recordNotification(_ record: NotificationRecord) async {
        do {
            try await notificationStore.append(record)
        } catch {
            logger.error("[Notifications] failed to record notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Context

    /// The session key plus its resolved id after CLI session renames.
    func notificationSessionKeys(_ sessionKey: String?) -> Set<String> {
        guard let sessionKey, !sessionKey.isEmpty else { return [] }
        return [sessionKey, resolveCurrentSessionId(sessionKey)]
    }

    /// Polls until none of `sessionKeys` is streaming, for at most 30 minutes.
    func waitForSessionsToFinish(_ sessionKeys: Set<String>) async {
        let deadline = Date.now.addingTimeInterval(30 * 60)
        // Let the tool call's own turn continue before the first check.
        try? await Task.sleep(for: .seconds(2))
        while Date.now < deadline,
              sessionKeys.contains(where: { sessionStates[resolveCurrentSessionId($0)]?.isStreaming == true }) {
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// When the current turn of the source chat started: its latest user
    /// message.
    private func runStartDate(for sessionKeys: Set<String>) -> Date? {
        sessionKeys
            .compactMap { sessionStates[resolveCurrentSessionId($0)]?.messages.last(where: { $0.role == .user })?.timestamp }
            .max()
    }

    private func notificationDecisionContext(
        briefing: BriefingDocument,
        content: String,
        mode: BriefingNotificationMode,
        recipient: String?,
        sessionKey: String?,
        sessionKeys: Set<String>
    ) async -> BriefingNotificationDecision.Context {
        let project = briefing.projectId.flatMap { id in projects.first(where: { $0.id == id }) }
        let resolved = sessionKey.map(resolveCurrentSessionId)
        let messages = resolved.flatMap { sessionStates[$0]?.messages } ?? []
        let sourcePrompt = messages.first(where: { $0.role == .user })?.content
        let threadTitle = resolved.flatMap { threadStore.fetch(id: $0)?.title }
        let normalizedPrompt = sourcePrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheduled = normalizedPrompt.flatMap { prompt in
            scheduledTasks.first { task in
                let taskPrompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return !taskPrompt.isEmpty && prompt.contains(taskPrompt)
                    && (task.projectId == nil || task.projectId == briefing.projectId)
            }
        }
        let alreadySent = await notificationStore.history()
            .filter { $0.status == .sent && $0.sessionKey.map(sessionKeys.contains) == true }
            .map(\.subject)
        let imageCount = NotificationBodyImages.references(
            in: content, format: briefing.format, baseURL: briefingStore.folderURL(for: briefing.id)
        ).count

        return BriefingNotificationDecision.Context(
            briefingTitle: briefing.title,
            briefingFormat: briefing.format,
            briefingContent: content,
            imageCount: imageCount,
            projectName: project?.name,
            projectPath: project?.path,
            gitHubRepo: project?.gitHubRepo,
            mode: mode,
            recipient: recipient,
            sourceThreadTitle: threadTitle,
            sourcePrompt: sourcePrompt,
            scheduledTaskName: scheduled?.name,
            scheduledTaskSchedule: scheduled?.cronExpression,
            notificationsAlreadySent: alreadySent
        )
    }
}
