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

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            if let infoMessage {
                Text(infoMessage).foregroundStyle(.secondary).font(.callout)
            }
            if let accountEmail = list?.accountEmail {
                Section("Account") {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        Text(verbatim: accountEmail)
                        Spacer()
                        statusBadge(String(localized: "Account"), color: .secondary)
                    }
                }
            }
            Section {
                ForEach(list?.items ?? []) { email in
                    row(email)
                }
                if let list, list.items.isEmpty {
                    Text("No trusted emails yet. Add an address to send notifications somewhere other than your account email.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            } header: {
                Text("Trusted Emails")
            } footer: {
                Text("Each address gets a verification link that expires after 24 hours. Notifications can only go to verified addresses.")
            }
        }
        .overlay {
            if isLoading, list == nil { ProgressView() }
        }
        .navigationTitle("Trusted Emails")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add Email", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddTrustedEmailSheet(onAdded: { email in
                infoMessage = String(localized: "Verification link sent to \(email.email).")
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

    private func row(_ email: TrustedEmail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope").foregroundStyle(.secondary)
            Text(verbatim: email.email)
            Spacer()
            if busyId == email.id {
                ProgressView().controlSize(.small)
            }
            switch email.status {
            case .verified:
                statusBadge(String(localized: "Verified"), color: .green)
            case .pending:
                statusBadge(String(localized: "Pending"), color: .orange)
            case .expired:
                statusBadge(String(localized: "Expired"), color: .red)
            }
            Menu {
                if email.status != .verified {
                    Button("Resend Verification Link") { Task { await resend(email) } }
                }
                Button("Remove…", role: .destructive) { pendingRemoval = email }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busyId != nil)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
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
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History…", role: .destructive) { showClearConfirmation = true }
                    .disabled(records.isEmpty)
            }
        }
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
