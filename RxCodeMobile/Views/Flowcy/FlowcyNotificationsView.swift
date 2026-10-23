import RxCodeChatKit
import RxCodeCore
import SwiftUI
import UserNotifications

struct FlowcyNotificationsView: View {
    @State private var showingConnection = false
    var body: some View {
        FlowcyResourceView(title: "Notifications", path: "notifications")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Notification Settings", systemImage: "bell.badge") { showingConnection = true; MobileHaptics.buttonTap() }
                }
            }
            .sheet(isPresented: $showingConnection) { FlowcyPushSettingsView().mobileSheetPresentation() }
    }
}

struct FlowcyPushSettingsView: View {
    @Environment(MobileCloudState.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmingDisconnect = false
    @State private var permissionDenied = false
    @State private var working = false
    @State private var actionError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("This Device") {
                    LabeledContent("Name", value: cloud.push.deviceName)
                    LabeledContent("Status", value: cloud.push.isRegistered ? "Registered with Flowcy" : cloud.push.isEnabled ? "Not registered" : "Disconnected")
                    if let environment = cloud.push.environment { LabeledContent("Environment", value: environment.capitalized) }
                    Text("Flowcy can send notifications to this device without a paired Mac.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if permissionDenied {
                        Button("Open System Notification Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    } else {
                        Button(cloud.push.isEnabled ? "Enable or Retry Registration" : "Connect Notifications") { Task { await enable() } }
                    }
                    if cloud.push.isRegistered {
                        Button("Disconnect Notifications", role: .destructive) { confirmingDisconnect = true; MobileHaptics.attentionNeeded() }
                    }
                    if let error = cloud.push.error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Notifications")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .disabled(working || cloud.push.isWorking)
            .overlay { if working || cloud.push.isWorking { ProgressView("Updating notifications…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .confirmationDialog("Disconnect this device from Flowcy notifications?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    working = true
                    Task {
                        defer { working = false }
                        do { try await cloud.push.disconnect(accountID: cloud.accountID, disable: true); MobileHaptics.connected() }
                        catch { actionError = cloud.push.error; MobileHaptics.connectionError() }
                    }
                }
            }
            .alert("Notification Settings", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) { Button("OK") { actionError = nil } } message: { Text(actionError ?? "") }
            .task { permissionDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied }
        }
    }
    private func enable() async {
        working = true; MobileHaptics.buttonTap(); defer { working = false }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            permissionDenied = !allowed
            guard allowed else { MobileHaptics.attentionNeeded(); return }
            await cloud.push.enable(accountID: cloud.accountID)
            UIApplication.shared.registerForRemoteNotifications()
            if cloud.push.isRegistered { MobileHaptics.connected() }
        } catch { actionError = "Could not request notification permission. Try again."; MobileHaptics.connectionError() }
    }
}

struct FlowcyPushDestinationView: View {
    let destination: FlowcyPushDestination
    let onOpenChat: (String) -> Void
    @Environment(MobileCloudState.self) private var cloud
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @State private var route: MobileTaskRoute?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("Opening notification…") }
                else if let error {
                    ContentUnavailableView { Label("Unable to Open Notification", systemImage: "exclamationmark.triangle") } description: { Text(error) } actions: { Button("Retry") { Task { await load() } } }
                } else if let route {
                    switch route {
                    case .board(let projectID): MobileTaskBoardView(projectID: projectID, onOpenChat: onOpenChat, isModal: false)
                    case .task(let projectID, let taskID): MobileTaskDetailView(projectID: projectID, taskID: taskID, onOpenChat: onOpenChat)
                    case .story(let projectID, let storyID): MobileStoryDetailView(projectID: projectID, storyID: storyID, onOpenChat: onOpenChat)
                    }
                } else { FlowcyNotificationsView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(MobileTaskDestinations(onOpenChat: onOpenChat))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }
    private func load() async {
        guard let remoteID = destination.projectID else { return }
        loading = true; error = nil; defer { loading = false }
        do {
            guard cloud.isSignedIn else { throw FlowcyError.signIn }
            state.usesCloudTasks = true
            try await state.refreshCloudTaskProjects()
            guard let project = state.cloudTaskProjects.first(where: { $0.cloudId == remoteID }) else { throw FlowcyError.denied }
            try await state.loadTaskBoard(projectID: project.id)
            try Task.checkCancellation()
            let board = state.taskBoard(for: project.id)
            if let taskID = destination.taskID {
                guard let local = board.cloudSync?.localTaskId(forRemote: taskID) else { throw FlowcyError.message("This task is no longer available.") }
                route = .task(projectID: project.id, taskID: local)
            } else if let storyID = destination.storyID {
                guard let local = board.cloudSync?.localStoryId(forRemote: storyID) else { throw FlowcyError.message("This story is no longer available.") }
                route = .story(projectID: project.id, storyID: local)
            } else { route = .board(project.id) }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

/// Notification content uses a readable column; delivery metadata stays in its own section.
struct FlowcyNotificationDetailView: View {
    let value: JSONValue

    static func title(_ value: JSONValue) -> String {
        for key in ["subject", "title"] {
            if let text = value[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        return "Notification"
    }

    private var createdAt: Date? {
        guard let raw = value["createdAt"]?.stringValue else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Self.title(value))
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let createdAt {
                        Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 12) {
                    if let status = value["status"]?.stringValue {
                        LabeledContent("Status") {
                            Label(status.capitalized, systemImage: status == "sent" ? "checkmark.circle" : status == "failed" ? "exclamationmark.circle" : "clock")
                                .foregroundStyle(status == "failed" ? Color.red : Color.secondary)
                        }
                    }
                    if let channel = value["channel"]?.stringValue {
                        Divider()
                        LabeledContent("Channel", value: channel == "rxcode" ? "Push Notification" : channel.capitalized)
                    }
                    if value["channel"]?.stringValue == "email", let recipient = value["recipient"]?.stringValue {
                        Divider()
                        LabeledContent("To", value: recipient)
                    }
                }
                .font(.subheadline)
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))

                if let error = value["error"]?.stringValue, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let body = value["body"]?.stringValue ?? value["content"]?.stringValue, !body.isEmpty {
                    MarkdownContentView(text: body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .textSelection(.enabled)
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Notification")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("flowcy-notification-detail")
    }
}
