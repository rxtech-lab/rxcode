import Foundation
import RxAuthSwift
import RxCodeCore

// MARK: - Notification IDE tool
//
// Lets agents send the user an Autopilot notification — e.g. when a scheduled
// task's prompt asks for its report to be emailed. Sends are recorded with the
// calling session, so the automatic briefing notification skips that run.

extension AppState {
    @MainActor
    func handleSendNotification(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        guard isSignedIn else {
            throw IDEToolError.invalidArguments("Notifications need an Autopilot account. Ask the user to sign in under Settings → Autopilot.")
        }
        let subjectArgument = arguments["subject"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let recipient = briefingNotificationSettings.recipient
        let record: NotificationRecord

        let rawBriefingId = arguments["briefing_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawBriefingId.isEmpty {
            guard let id = UUID(uuidString: rawBriefingId) else {
                throw IDEToolError.invalidArguments("'briefing_id' must be a briefing UUID. Call ide__briefing_list to find one.")
            }
            let briefing: BriefingDocument
            do {
                briefing = try await briefingStore.load(id)
            } catch {
                throw IDEToolError.invalidArguments(error.localizedDescription)
            }
            record = await sendNotification(
                subject: subjectArgument.isEmpty ? briefing.title : subjectArgument,
                body: await briefingDocumentContent(briefing),
                format: briefing.format,
                imageBaseURL: briefingStore.folderURL(for: briefing.id),
                recipient: recipient,
                source: .agent,
                briefing: briefing,
                sessionKey: sessionKey
            )
        } else {
            let body = arguments["body"]?.stringValue ?? ""
            guard !subjectArgument.isEmpty, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IDEToolError.invalidArguments("Pass a nonempty 'subject' and 'body', or a 'briefing_id'.")
            }
            let format: BriefingContentFormat?
            switch arguments["format"]?.stringValue?.lowercased() ?? "markdown" {
            case "text": format = nil
            case "markdown": format = .markdown
            case "html": format = .html
            default: throw IDEToolError.invalidArguments("'format' must be 'text', 'markdown', or 'html'.")
            }
            let projectId = threadStore.fetch(id: resolveCurrentSessionId(sessionKey))?.projectId
            let project = projectId.flatMap { id in projects.first(where: { $0.id == id }) }
            let base = project.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            record = await sendNotification(
                subject: subjectArgument,
                body: body,
                format: format,
                imageBaseURL: base,
                recipient: recipient,
                source: .agent,
                projectId: project?.id,
                sessionKey: sessionKey
            )
        }

        guard record.status == .sent else {
            throw IDEToolError.invalidArguments("The notification wasn't sent: \(record.errorMessage ?? "unknown error")")
        }
        return jsonTextResult(.object([
            "status": .string("sent"),
            "id": record.remoteId.map { .string($0) } ?? .null,
            "subject": .string(record.subject),
            "recipient": .string(recipient ?? rxUser?.email ?? "account email"),
        ]))
    }
}
