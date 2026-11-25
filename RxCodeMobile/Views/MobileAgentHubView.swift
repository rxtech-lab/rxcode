import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

struct MobileAgentHubView: View {
    @EnvironmentObject private var state: MobileAppState
    var onPair: () -> Void = {}

    var body: some View {
        Group {
            if !state.isPaired {
                ContentUnavailableView {
                    Label("Connect a Mac", systemImage: "laptopcomputer")
                } actions: { Button("Pair Mac", action: onPair) }
            } else if state.agentHub.agents.isEmpty {
                ContentUnavailableView("No Agents", systemImage: "person.2", description: Text("Create an agent in RxCode on your paired Mac."))
            } else {
                List(state.agentHub.agents) { agent in
                    NavigationLink { MobileAgentDetail(agentID: agent.id) } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(agent.profile.displayName)
                                if let notice = agent.profile.phoneMessages.first {
                                    Text(notice.body).lineLimit(1).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        } icon: { Image(systemName: agent.profile.symbol) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Chat")
        .task(id: state.pairedDesktopPubkey) {
            if state.isPaired { try? await state.sendAgentPayload(.agentRequest(.init(operation: .refresh))) }
        }
    }
}

private struct MobileAgentDetail: View {
    @EnvironmentObject private var state: MobileAppState
    let agentID: UUID
    @State private var screen = false
    @State private var message = ""
    @State private var request: UUID?
    @State private var error: String?
    @State private var openedThread: String?

    var body: some View {
        List {
            if let agent = state.agentHub.agent(id: agentID) {
                if let session = agent.primarySessionId {
                    NavigationLink("Conversation") { MobileChatView(sessionID: session) }
                } else {
                    TextField("Message", text: $message, axis: .vertical)
                    Button("Send") { send() }.disabled(request != nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !agent.profile.phoneMessages.isEmpty {
                    NavigationLink("Messages from Agent") {
                        List(agent.profile.phoneMessages) { notice in
                            VStack(alignment: .leading, spacing: 4) {
                                MarkdownContentView(text: notice.body, style: .rxCodeCompact)
                                Text(notice.sentAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                                if let session = notice.sessionID {
                                    NavigationLink("Open Conversation") { MobileChatView(sessionID: session) }
                                }
                            }
                        }.navigationTitle("Messages from Agent")
                    }
                }
                Button("View Mac Screen", systemImage: "display") { MobileHaptics.buttonTap(); screen = true }
                    .disabled(!state.agentHub.remoteAccess.allowsViewing)
                NavigationLink("Jobs") {
                    let jobs = state.agentHub.jobs(for: agentID)
                    List(jobs) { job in
                        NavigationLink {
                            if let key = job.sessionKey { MobileChatView(sessionID: key) }
                            else { ScrollView { MarkdownContentView(text: job.errorMessage ?? job.resultSummary ?? job.prompt).padding() } }
                        } label: {
                            VStack(alignment: .leading) {
                                Label(job.title, systemImage: job.kind.systemImage)
                                Text(job.status.displayName).font(.caption)
                            }
                        }
                    }.overlay { if jobs.isEmpty { ContentUnavailableView("No Jobs Yet", systemImage: "tray") } }.navigationTitle("Jobs")
                }
                NavigationLink("Memory") {
                    let notes = state.agentHub.memory(for: agentID)
                    List(notes) { MarkdownContentView(text: $0.content, style: .rxCodeCompact) }
                        .overlay { if notes.isEmpty { ContentUnavailableView("No Memory Yet", systemImage: "brain") } }.navigationTitle("Memory")
                }
                NavigationLink("Schedules") {
                    let tasks = state.agentHub.schedules(for: agentID)
                    List(tasks) { task in
                        LabeledContent(task.name, value: task.dueAt?.formatted() ?? task.cronExpression)
                    }.overlay { if tasks.isEmpty { ContentUnavailableView("No Schedules", systemImage: "calendar") } }.navigationTitle("Schedules")
                }
            }
        }
        .navigationTitle(state.agentHub.agent(id: agentID)?.profile.displayName ?? "Agent")
        .navigationDestination(item: $openedThread) { MobileChatView(sessionID: $0) }
        .sheet(isPresented: $screen) { MobileAgentScreenView().environmentObject(state) }
        .overlay { if request != nil { ProgressView("Sending…").padding().background(.regularMaterial, in: .rect(cornerRadius: 14)) } }
        .onReceive(state.$latestAgentResult) { result in
            guard let result, result.clientRequestID == request else { return }
            request = nil
            if result.ok { message = ""; openedThread = result.sessionID }
            else { error = result.error }
        }
        .task(id: request) {
            guard request != nil else { return }
            do { try await Task.sleep(for: .seconds(30)); request = nil; error = "The Mac has not confirmed delivery. Check the conversation before retrying." } catch {}
        }
        .alert("Message Delivery", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }

    private func send() {
        MobileHaptics.buttonTap()
        let payload = AgentRequestPayload(operation: .sendMessage, agentID: agentID, text: message)
        request = payload.clientRequestID
        Task {
            do { try await state.sendAgentPayload(.agentRequest(payload)) }
            catch { request = nil; self.error = error.localizedDescription }
        }
    }
}

extension MobileAppState {
    func sendAgentPayload(_ payload: RxCodeSync.Payload) async throws {
        guard isPaired else { throw URLError(.notConnectedToInternet) }
        try await client.send(payload, toHex: pairedDesktopPubkey)
    }
}
