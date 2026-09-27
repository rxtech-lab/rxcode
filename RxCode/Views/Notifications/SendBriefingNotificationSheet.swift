import RxAuthSwift
import RxCodeCore
import SwiftUI

/// Emails a briefing through the Autopilot notification service, opened from
/// the briefing card's send button. Local images are uploaded and embedded.
struct SendBriefingNotificationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let document: BriefingDocument

    @State private var subject: String
    @State private var recipient: String?
    @State private var trusted: TrustedEmailList?
    @State private var usage: AutopilotNotificationUsage?
    @State private var imageCount = 0
    @State private var alreadySent = false
    @State private var isSending = false
    @State private var errorMessage: String?

    init(document: BriefingDocument) {
        self.document = document
        _subject = State(initialValue: document.title)
    }

    private var canSend: Bool {
        appState.isSignedIn && !isSending
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && usage.map { $0.used < $0.limit } ?? true
    }

    var body: some View {
        NavigationStack {
            Form {
                if !appState.isSignedIn {
                    Section {
                        Label("Sign in to Autopilot under Settings → Autopilot to send notifications.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(ClaudeTheme.statusWarning)
                    }
                }

                Section {
                    TextField("Subject", text: $subject)
                        .accessibilityIdentifier("send-notification-subject")
                    recipientPicker
                    LabeledContent("Channel", value: String(localized: "Email"))
                } footer: {
                    footer
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSending)
            .navigationTitle("Send Notification")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(!canSend)
                            .accessibilityIdentifier("send-notification-confirm")
                    }
                }
            }
        }
        .frame(width: 460, height: 340)
        .task { await load() }
    }

    private var recipientPicker: some View {
        let accountEmail = trusted?.accountEmail ?? appState.rxUser?.email
        let verified = trusted?.allowedRecipients.filter { $0 != accountEmail } ?? []
        return Picker("Send to", selection: $recipient) {
            Text(accountEmail.map { "Account email (\($0))" } ?? String(localized: "Account email"))
                .tag(String?.none)
            ForEach(verified, id: \.self) { email in
                Text(verbatim: email).tag(Optional(email))
            }
            if let current = recipient, !verified.contains(current) {
                Text("\(current) (not verified)").tag(Optional(current))
            }
        }
        .accessibilityIdentifier("send-notification-recipient")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.format == .html
                ? "The briefing's HTML is sent as the email body."
                : "The briefing's markdown is sent as the email body.")
            if imageCount > 0 {
                Text("^[\(imageCount) image](inflect: true) will be uploaded and embedded.")
            }
            if alreadySent {
                Text("This briefing was already sent. Sending again delivers another email.")
                    .foregroundStyle(ClaudeTheme.statusWarning)
            }
            if let usage {
                Text("\(usage.used) of \(usage.limit) notifications sent today.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func load() async {
        recipient = appState.briefingNotificationSettings.recipient
        alreadySent = await appState.notificationStore.hasSent(briefingId: document.id)
        let content = await appState.briefingDocumentContent(document)
        imageCount = NotificationBodyImages.references(
            in: content, format: document.format, baseURL: appState.briefingStore.folderURL(for: document.id)
        ).count
        guard appState.isSignedIn else { return }
        async let list = appState.autopilotNotifications.listTrustedEmails()
        async let today = appState.autopilotNotifications.usage()
        trusted = try? await list
        usage = try? await today
    }

    private func send() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        let record = await appState.sendBriefingNotification(document, subject: subject, recipient: recipient)
        if record.status == .sent {
            dismiss()
        } else {
            errorMessage = record.errorMessage ?? String(localized: "The notification wasn't sent.")
        }
    }
}
