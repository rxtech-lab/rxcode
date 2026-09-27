import RxAuthSwift
import RxCodeCore
import SwiftUI

/// "Manage Notifications" sheet opened from Settings → Autopilot. Configures
/// sending published briefings through the Autopilot notification service and
/// drills into trusted emails, per-project modes and the local history.
struct NotificationSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Route: Hashable {
        case trustedEmails
        case projects
        case history
    }

    @State private var trusted: TrustedEmailList?
    @State private var usage: AutopilotNotificationUsage?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            form
                .navigationTitle("Notifications")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .trustedEmails:
                        TrustedEmailsView(onChange: { list in trusted = list })
                    case .projects:
                        ProjectNotificationModesView()
                    case .history:
                        NotificationHistoryView()
                    }
                }
        }
        .frame(width: 560, height: 560)
        .task { await reload() }
    }

    private var settings: BriefingNotificationSettings { appState.briefingNotificationSettings }

    private var form: some View {
        Form {
            Section {
                Toggle("Send briefings as notifications", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { value in appState.updateBriefingNotificationSettings { $0.isEnabled = value } }
                ))
                Picker("Default for projects", selection: Binding(
                    get: { settings.defaultMode },
                    set: { value in appState.updateBriefingNotificationSettings { $0.defaultMode = value } }
                )) {
                    ForEach(BriefingNotificationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!settings.isEnabled)
                recipientPicker
                    .disabled(!settings.isEnabled)
            } header: {
                Text("Briefings")
            } footer: {
                Text("When an agent publishes a briefing, RxCode waits for its run to finish. If the run hasn't already sent a notification, the general AI task agent reads the briefing and the project's settings and decides whether to email it. Local images are uploaded as WebP attachments.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
            }

            Section {
                NavigationLink(value: Route.trustedEmails) {
                    Label {
                        HStack {
                            Text("Trusted Emails")
                            Spacer()
                            if let trusted {
                                Text("\(trusted.items.count)").foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "envelope.badge.shield.half.filled")
                    }
                }
                NavigationLink(value: Route.projects) {
                    Label("Projects", systemImage: "folder")
                }
                NavigationLink(value: Route.history) {
                    Label {
                        HStack {
                            Text("History")
                            Spacer()
                            if let usage {
                                Text("\(usage.used) of \(usage.limit) sent today").foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var recipientPicker: some View {
        let accountEmail = trusted?.accountEmail ?? appState.rxUser?.email
        let verified = trusted?.allowedRecipients.filter { $0 != accountEmail } ?? []
        return Picker("Send to", selection: Binding(
            get: { settings.recipient },
            set: { value in appState.updateBriefingNotificationSettings { $0.recipient = value } }
        )) {
            Text(accountEmail.map { "Account email (\($0))" } ?? String(localized: "Account email"))
                .tag(String?.none)
            ForEach(verified, id: \.self) { email in
                Text(verbatim: email).tag(Optional(email))
            }
            // Keep a saved choice selectable even if it's no longer verified.
            if let current = settings.recipient, !verified.contains(current) {
                Text("\(current) (not verified)").tag(Optional(current))
            }
        }
    }

    private func reload() async {
        errorMessage = nil
        do {
            async let list = appState.autopilotNotifications.listTrustedEmails()
            async let today = appState.autopilotNotifications.usage()
            trusted = try await list
            usage = try? await today
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension BriefingNotificationMode {
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Let the agent decide"
        case .always: "Always send"
        case .never: "Never send"
        }
    }
}

// MARK: - Trusted emails

/// Lists trusted emails with their verification status. Adding happens in
/// `AddTrustedEmailSheet`; removing asks for confirmation.
private struct TrustedEmailsView: View {
    @Environment(AppState.self) private var appState
    var onChange: (TrustedEmailList) -> Void

    @State private var list: TrustedEmailList?
    @State private var isLoading = false
    @State private var busyId: String?
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var showAdd = false
    @State private var pendingRemoval: TrustedEmail?

    /// Autopilot's per-account cap on trusted emails.
    private let trustedEmailLimit = 10

    private var recipient: String? { appState.briefingNotificationSettings.recipient }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 22))
                        .foregroundStyle(ClaudeTheme.accent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Where notifications can go")
                            .font(.headline)
                        Text("Notifications go to your account email unless you choose a trusted email. New addresses get a verification link that expires after 24 hours.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage {
                Section {
                    banner(errorMessage, systemImage: "exclamationmark.triangle.fill", color: .red)
                }
            } else if let infoMessage {
                Section {
                    banner(infoMessage, systemImage: "paperplane.fill", color: .accentColor)
                }
            }

            if let accountEmail = list?.accountEmail {
                Section("Account") {
                    EmailRow(
                        email: accountEmail,
                        systemImage: "person.crop.circle.fill",
                        tint: .accentColor,
                        detail: String(localized: "Your Autopilot account email"),
                        isRecipient: recipient == nil
                    ) {
                        if recipient != nil {
                            Button("Use for Notifications") {
                                appState.updateBriefingNotificationSettings { $0.recipient = nil }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                if let list, list.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No trusted emails yet")
                            .font(.callout.weight(.medium))
                        Text("Add a teammate's or work address to send notifications there.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                ForEach(list?.items ?? []) { email in
                    trustedRow(email)
                }
            } header: {
                HStack {
                    Text("Trusted Emails")
                    Spacer()
                    if let list {
                        Text("\(list.items.count) of \(trustedEmailLimit)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                // Toolbar items of a view pushed inside a macOS sheet aren't
                // shown, so the add action lives in the form.
                Button {
                    showAdd = true
                } label: {
                    Label("Add Trusted Email…", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled((list?.items.count ?? 0) >= trustedEmailLimit)
                .accessibilityIdentifier("add-trusted-email")
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isLoading, list == nil { ProgressView() }
        }
        .navigationTitle("Trusted Emails")
        .sheet(isPresented: $showAdd) {
            AddTrustedEmailSheet(onAdded: { email in
                errorMessage = nil
                infoMessage = String(localized: "Verification link sent to \(email.email). It expires in 24 hours.")
                Task { await reload() }
            })
            .environment(appState)
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.email ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { email in
            Button("Remove", role: .destructive) {
                Task { await remove(email) }
            }
        } message: { _ in
            Text("Notifications will no longer be sent to this address.")
        }
        .task { await reload() }
    }

    private func trustedRow(_ email: TrustedEmail) -> some View {
        let isRecipient = recipient?.caseInsensitiveCompare(email.email) == .orderedSame
        return EmailRow(
            email: email.email,
            systemImage: email.status.systemImage,
            tint: email.status.color,
            detail: statusDetail(email),
            isRecipient: isRecipient
        ) {
            if busyId == email.id {
                ProgressView().controlSize(.small)
            } else {
                switch email.status {
                case .verified:
                    if !isRecipient {
                        Button("Use for Notifications") {
                            appState.updateBriefingNotificationSettings { $0.recipient = email.email }
                        }
                        .buttonStyle(.borderless)
                    }
                case .pending, .expired:
                    Button("Resend Link") { Task { await resend(email) } }
                        .buttonStyle(.borderless)
                }
                Button {
                    pendingRemoval = email
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(email.email)")
                .disabled(busyId != nil)
            }
        }
    }

    private func statusDetail(_ email: TrustedEmail) -> String {
        switch email.status {
        case .verified:
            if let date = Self.parseDate(email.verifiedAt) {
                return String(localized: "Verified \(date.formatted(date: .abbreviated, time: .omitted))")
            }
            return String(localized: "Verified")
        case .pending:
            return String(localized: "Waiting for confirmation — check that inbox for the link")
        case .expired:
            return String(localized: "Verification link expired — resend it to try again")
        }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private func banner(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.callout)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await appState.autopilotNotifications.listTrustedEmails()
            list = loaded
            errorMessage = nil
            onChange(loaded)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resend(_ email: TrustedEmail) async {
        busyId = email.id
        defer { busyId = nil }
        do {
            _ = try await appState.autopilotNotifications.addTrustedEmail(email.email)
            errorMessage = nil
            infoMessage = String(localized: "Verification link sent to \(email.email).")
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ email: TrustedEmail) async {
        busyId = email.id
        defer { busyId = nil }
        do {
            try await appState.autopilotNotifications.removeTrustedEmail(id: email.id)
            if appState.briefingNotificationSettings.recipient?.caseInsensitiveCompare(email.email) == .orderedSame {
                appState.updateBriefingNotificationSettings { $0.recipient = nil }
            }
            errorMessage = nil
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One address in the trusted emails list: a tinted icon, the address with
/// a status line, a "Receives notifications" marker, and trailing actions.
private struct EmailRow<Actions: View>: View {
    let email: String
    let systemImage: String
    let tint: Color
    let detail: String
    let isRecipient: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: email)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isRecipient {
                        Text("Receives notifications")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                actions()
            }
            .font(.callout)
        }
        .padding(.vertical, 3)
    }
}

private extension TrustedEmail.Status {
    var systemImage: String {
        switch self {
        case .verified: "checkmark.seal.fill"
        case .pending: "clock.fill"
        case .expired: "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .verified: .green
        case .pending: .orange
        case .expired: .red
        }
    }
}

// MARK: - Projects

/// Per-project override of the default briefing notification mode.
private struct ProjectNotificationModesView: View {
    @Environment(AppState.self) private var appState

    private var projects: [Project] {
        appState.projects.filter { !$0.isGlobalChat }
    }

    var body: some View {
        Form {
            Section {
                ForEach(projects) { project in
                    Picker(selection: binding(for: project.id)) {
                        Text("Default (\(Text(appState.briefingNotificationSettings.defaultMode.title)))")
                            .tag(BriefingNotificationMode?.none)
                        ForEach(BriefingNotificationMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(Optional(mode))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: project.name)
                            if let repo = project.gitHubRepo {
                                Text(verbatim: repo).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if projects.isEmpty {
                    Text("No projects yet.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("The project's setting is shared with the general AI task agent when it decides whether to send a briefing.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Projects")
        .disabled(!appState.briefingNotificationSettings.isEnabled)
    }

    private func binding(for projectId: UUID) -> Binding<BriefingNotificationMode?> {
        Binding(
            get: { appState.briefingNotificationSettings.projectModes[projectId] },
            set: { mode in appState.updateBriefingNotificationSettings { $0.projectModes[projectId] = mode } }
        )
    }
}

// MARK: - History

/// Notifications recorded on this Mac: sent, failed, and briefings that were
/// deliberately not sent.
private struct NotificationHistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var records: [NotificationRecord] = []
    @State private var showClearConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            ForEach(records) { record in
                HistoryRow(record: record, projectName: projectName(record.projectId))
            }
            if records.isEmpty {
                Text("No notifications yet.").foregroundStyle(.secondary)
            } else {
                Button("Clear History…", role: .destructive) { showClearConfirmation = true }
                    .buttonStyle(.borderless)
            }
        }
        .navigationTitle("History")
        .confirmationDialog("Clear notification history?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                Task { await clear() }
            }
        } message: {
            Text("This removes the history stored on this Mac. RxCode also uses it to avoid sending a briefing twice.")
        }
        .task { records = await appState.notificationHistory() }
    }

    private func projectName(_ id: UUID?) -> String? {
        id.flatMap { id in appState.projects.first(where: { $0.id == id })?.name }
    }

    private func clear() async {
        do {
            try await appState.clearNotificationHistory()
            records = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HistoryRow: View {
    let record: NotificationRecord
    let projectName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.subject).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let message = record.errorMessage ?? record.reason, !message.isEmpty {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
                        .lineLimit(2)
                        .help(message)
                }
            }
            Spacer()
            Text(record.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch record.status {
        case .sent: "paperplane.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .skipped: "minus.circle"
        }
    }

    private var color: Color {
        switch record.status {
        case .sent: .green
        case .failed: .red
        case .skipped: .secondary
        }
    }

    private var detail: String {
        var parts: [String] = []
        switch record.status {
        case .sent: parts.append(String(localized: "Sent"))
        case .failed: parts.append(String(localized: "Failed"))
        case .skipped: parts.append(String(localized: "Not sent"))
        }
        switch record.source {
        case .briefing: parts.append(String(localized: "Briefing"))
        case .agent: parts.append(String(localized: "Agent"))
        case .scheduledTask: parts.append(String(localized: "Scheduled task"))
        case .user: parts.append(String(localized: "Sent by you"))
        }
        if let recipient = record.recipient { parts.append(recipient) }
        if let projectName { parts.append(projectName) }
        return parts.joined(separator: " · ")
    }
}
