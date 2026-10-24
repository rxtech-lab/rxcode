import RxCodeCore
import RxCodeChatKit
import SwiftUI

struct FlowcySessionDetailView: View {
    let id: String
    @State private var messages: [JSONValue] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedActivity: SessionActivity?

    private struct TranscriptRow: Identifiable {
        let id: Int
        let message: JSONValue
        let tools: [ToolCall]
    }

    private var visibleMessages: [TranscriptRow] {
        let groups = SavedSessionToolCalls.groups(in: messages)
        return messages.enumerated().compactMap { index, message in
            guard !Self.messageText(message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !groups[index].isEmpty else { return nil }
            return TranscriptRow(id: index, message: message, tools: groups[index])
        }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading conversation…")
            } else if let error {
                ContentUnavailableView {
                    Label("Unable to Load Conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        MobileHaptics.buttonTap()
                        Task { await load() }
                    }
                }
            } else if visibleMessages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Messages from this session will appear here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Label("Saved conversation", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 8)
                        ForEach(visibleMessages) { row in
                            VStack(alignment: .leading, spacing: 12) {
                                if !Self.messageText(row.message).isEmpty { messageRow(row.message) }
                                if !row.tools.isEmpty { ToolActivityGroupView(tools: row.tools) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .accessibilityIdentifier("flowcy-session-transcript")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClaudeTheme.background)
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedActivity) { activity in
            NavigationStack {
                ScrollView {
                    MarkdownContentView(text: activity.text)
                        .textSelection(.enabled)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(activity.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            MobileHaptics.buttonTap()
                            selectedActivity = nil
                        }
                    }
                }
            }
            .mobileSheetPresentation()
        }
        .task(id: id) { await load() }
    }

    @ViewBuilder
    private func messageRow(_ message: JSONValue) -> some View {
        let role = message["role"]?.stringValue ?? "assistant"
        let text = Self.messageText(message)
        if role == "user" {
            HStack(spacing: 0) {
                Spacer(minLength: 40)
                MarkdownContentView(text: text, style: .rxCodeChatUser, expandsHorizontally: false)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(ClaudeTheme.userBubble, in: UnevenRoundedRectangle(
                        topLeadingRadius: 22, bottomLeadingRadius: 22,
                        bottomTrailingRadius: 5, topTrailingRadius: 22
                    ))
            }
            .accessibilityIdentifier("flowcy-session-user-message")
        } else if role == "tool" || role == "system" {
            Button {
                MobileHaptics.buttonTap()
                selectedActivity = SessionActivity(title: role == "system" ? "Session Details" : "Tool Activity", text: text)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: role == "system" ? "info.circle" : "wrench.and.screwdriver")
                    Text(message["name"]?.stringValue ?? (role == "system" ? "Session Details" : "Tool Activity"))
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption2.bold())
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(ClaudeTheme.surfacePrimary, in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("Assistant", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                MarkdownContentView(text: text)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityIdentifier("flowcy-session-assistant-message")
        }
    }

    private static func messageText(_ message: JSONValue) -> String {
        var sections: [String] = []
        let content = message["content"]?.stringValue
            ?? message["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
        if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(content)
        }
        return sections.joined(separator: "\n\n")
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let result = try await FlowcyAPI().read("sessions/" + escaped)
            try Task.checkCancellation()
            messages = result["messages"]?.arrayValue ?? []
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private struct SessionActivity: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
}

struct FlowcyBillingView: View {
    @State private var subscription: JSONValue?
    @State private var loading = false
    @State private var error: String?
    @State private var reloadID = UUID()
    @State private var activeLoadID: UUID?

    var body: some View {
        Form {
            if let subscription {
                Section("Subscription") {
                    LabeledContent("Plan", value: subscription["tier"]?.stringValue?.capitalized ?? "Unknown")
                    LabeledContent("Status", value: subscription["status"]?.stringValue?.capitalized ?? "Unknown")
                }
            }
            Section("Manage Your Subscription") {
                Text("To view or change your subscription and billing details, sign in to your account on the Flowcy website using a web browser.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Billing")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView("Loading…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .alert("Billing", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Retry") {
                MobileHaptics.buttonTap()
                error = nil
                reloadID = UUID()
            }
            Button("Cancel", role: .cancel) {
                MobileHaptics.buttonTap()
                error = nil
            }
        } message: { Text(error ?? "") }
        .task(id: reloadID) { await load() }
    }

    private func load() async {
        let loadID = UUID()
        activeLoadID = loadID
        loading = true
        error = nil
        defer {
            if activeLoadID == loadID { loading = false }
        }
        do {
            let result = try await FlowcyAPI().read("subscriptions")
            try Task.checkCancellation()
            guard activeLoadID == loadID else { return }
            subscription = result.isNull ? nil : result
        } catch {
            // Navigation can cancel URLSession with URLError.cancelled instead of CancellationError.
            guard activeLoadID == loadID, !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
