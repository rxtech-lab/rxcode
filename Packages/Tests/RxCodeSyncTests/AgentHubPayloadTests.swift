import Foundation
import RxCodeCore
import Testing
@testable import RxCodeSync

@Suite("Agent hub and screen sharing payloads")
struct AgentHubPayloadTests {
    private func roundTrip(_ payload: Payload) throws -> (json: String, decoded: Payload) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        return (String(decoding: data, as: UTF8.self), try decoder.decode(Payload.self, from: data))
    }

    @Test("the hub update round trips with agents, memory, jobs and schedules")
    func hubUpdateRoundTrip() throws {
        let agent = AgentProfile(name: "Atlas", agent: TaskAgentConfig(provider: .claudeCode, model: "claude-opus-5-5"))
        var schedule = ScheduledTask(name: "Brief", prompt: "Summarize", cronExpression: "0 8 * * *")
        schedule.agentId = agent.id
        let snapshot = AgentHubSnapshot(
            agents: [AgentHubAgent(profile: agent, modelLabel: "Opus", primarySessionId: "s1",
                                   lastMessagePreview: "Hi", isStreaming: true, isUsingComputer: true)],
            memory: [AgentMemoryNote(agentId: agent.id, content: "Likes tea", kind: .preference)],
            jobs: [AgentJob(agentId: agent.id, kind: .scheduled, title: "Brief", prompt: "Summarize", scheduleId: schedule.id)],
            schedules: [schedule],
            remoteAccess: AgentRemoteAccessPolicy(allowsViewing: true, allowsControl: true),
            canCaptureScreen: true
        )
        let (json, decoded) = try roundTrip(.agentHubUpdate(AgentHubUpdatePayload(snapshot: snapshot, seq: 7)))
        #expect(json.contains(#""type":"agent_hub_update""#))
        guard case .agentHubUpdate(let update) = decoded else {
            Issue.record("Expected agent_hub_update")
            return
        }
        #expect(update.seq == 7)
        #expect(update.snapshot.agents.first?.profile.name == "Atlas")
        #expect(update.snapshot.memory(for: agent.id).first?.content == "Likes tea")
        #expect(update.snapshot.jobs(for: agent.id).first?.scheduleId == schedule.id)
        #expect(update.snapshot.schedules(for: agent.id).first?.agentId == agent.id)
        #expect(update.snapshot.remoteAccess.allowsControl)
        #expect(update.snapshot.agent(id: agent.id)?.isUsingComputer == true)
    }

    @Test("a hub snapshot from an older desktop decodes with defaults")
    func olderSnapshot() throws {
        let snapshot = try JSONDecoder().decode(AgentHubSnapshot.self, from: Data("{}".utf8))
        #expect(snapshot == AgentHubSnapshot())
    }

    @Test("requests keep their operation and an unknown operation decodes as unsupported")
    func requestRoundTrip() throws {
        let request = AgentRequestPayload(operation: .sendMessage, agentID: UUID(), text: "Book a table")
        let (json, decoded) = try roundTrip(.agentRequest(request))
        #expect(json.contains(#""type":"agent_request""#))
        guard case .agentRequest(let value) = decoded else {
            Issue.record("Expected agent_request")
            return
        }
        #expect(value.operation == .sendMessage)
        #expect(value.text == "Book a table")
        #expect(value.clientRequestID == request.clientRequestID)

        let future = Data(#"{"clientRequestID":"\#(UUID().uuidString)","operation":"teleport"}"#.utf8)
        #expect(try JSONDecoder().decode(AgentRequestPayload.self, from: future).operation == .unsupported)
    }

    @Test("frames carry their JPEG bytes intact")
    func frameRoundTrip() throws {
        let session = UUID()
        let bytes = Data((0..<512).map { UInt8($0 % 256) })
        let frame = ScreenFramePayload(sessionID: session, seq: 3, displayID: 1, jpeg: bytes, width: 1280, height: 800,
                                       cursorX: 0.5, cursorY: 0.25)
        let (json, decoded) = try roundTrip(.screenFrame(frame))
        #expect(json.contains(#""type":"screen_frame""#))
        guard case .screenFrame(let value) = decoded else {
            Issue.record("Expected screen_frame")
            return
        }
        #expect(value.jpeg == bytes)
        #expect(value.sessionID == session)
        #expect(value.cursorY == 0.25)
    }

    @Test("screen share state and control requests round trip")
    func shareStateRoundTrip() throws {
        let state = ScreenShareStatePayload(sessionID: UUID(), status: .active, controlGranted: true,
                                            displays: [ScreenShareDisplay(id: 1, name: "Built-in", width: 1512, height: 982)],
                                            activeDisplayID: 1)
        guard case .screenShareState(let value) = try roundTrip(.screenShareState(state)).decoded else {
            Issue.record("Expected screen_share_state")
            return
        }
        #expect(value == state)

        let request = ScreenShareRequestPayload(action: .requestControl, sessionID: state.sessionID)
        guard case .screenShareRequest(let decodedRequest) = try roundTrip(.screenShareRequest(request)).decoded else {
            Issue.record("Expected screen_share_request")
            return
        }
        #expect(decodedRequest.action == .requestControl)
    }

    @Test("remote input is validated before it reaches the Mac")
    func remoteInputValidation() throws {
        let session = UUID()
        #expect(RemoteInputPayload(sessionID: session, seq: 1, kind: .click, x: 0.2, y: 0.9).isWellFormed)
        #expect(!RemoteInputPayload(sessionID: session, seq: 1, kind: .click, x: 1.2, y: 0.9).isWellFormed)
        #expect(!RemoteInputPayload(sessionID: session, seq: 1, kind: .click, x: .nan, y: 0.9).isWellFormed)
        #expect(!RemoteInputPayload(sessionID: session, seq: 1, kind: .drag, x: 0.1, y: 0.1).isWellFormed)
        #expect(RemoteInputPayload(sessionID: session, seq: 1, kind: .scroll, deltaY: -120).isWellFormed)
        #expect(!RemoteInputPayload(sessionID: session, seq: 1, kind: .scroll, deltaY: 90_000).isWellFormed)
        #expect(RemoteInputPayload(sessionID: session, seq: 1, kind: .key, key: "cmd+space").isWellFormed)
        #expect(!RemoteInputPayload(sessionID: session, seq: 1, kind: .key, key: "cmd+banana").isWellFormed)
        #expect(!RemoteInputPayload(sessionID: session, seq: 1, kind: .text,
                                    text: String(repeating: "a", count: RemoteInputPayload.textLimit + 1)).isWellFormed)

        let input = RemoteInputPayload(sessionID: session, seq: 9, kind: .text, text: "hello")
        guard case .remoteInput(let value) = try roundTrip(.remoteInput(input)).decoded else {
            Issue.record("Expected remote_input")
            return
        }
        #expect(value.text == "hello")
        #expect(value.seq == 9)
    }

    @Test("payload log names match their wire types")
    func logNames() {
        let session = UUID()
        #expect(Payload.screenFrameAck(ScreenFrameAckPayload(sessionID: session, seq: 1)).logName == "screen_frame_ack")
        #expect(Payload.agentResult(AgentResultPayload(clientRequestID: session, ok: true)).logName == "agent_result")
    }
}
