import RxCodeCore
import XCTest
@testable import RxCode

/// Covers what happens when the user sends a second message while a turn is
/// still running.
///
/// The default is the queue: the message waits for the running turn to end.
/// From there the user picks — "steer now" hands it to the turn already in
/// flight, "send now" interrupts that turn and starts a new one. What matters
/// in each case is that the message is never lost and the turn is never
/// cancelled without the user asking for it.
@MainActor
final class AppStateSteeringTests: XCTestCase {

    private var appState: AppState!
    private var mockBackend: MockAgentBackend!
    private var window: WindowState!
    private var project: Project!
    private var sessionKey: String!
    private var defaultsSnapshot: [String: Any?] = [:]

    override func setUp() async throws {
        defaultsSnapshot = [
            "selectedAgentProvider": UserDefaults.standard.object(forKey: "selectedAgentProvider"),
            "selectedModel": UserDefaults.standard.object(forKey: "selectedModel"),
        ]
        UserDefaults.standard.set("claudeCode", forKey: "selectedAgentProvider")

        appState = AppState(startBackgroundServices: false)
        appState.selectedAgentProvider = .claudeCode

        mockBackend = MockAgentBackend(provider: .claudeCode)
        appState.agentBackendOverrides[.claudeCode] = mockBackend
        appState.agentBackendOverrides[.codex] = mockBackend
        appState.agentBackendOverrides[.acp] = mockBackend

        project = Project(
            name: "steering",
            path: "/tmp/rxcode-steering-\(UUID().uuidString)",
            gitHubRepo: nil
        )
        appState.projects = [project]

        sessionKey = "thread-\(UUID().uuidString)"
        window = WindowState()
        window.selectedProject = project
        window.currentSessionId = sessionKey
    }

    override func tearDown() async throws {
        for key in appState.sessionStates.keys where appState.sessionStates[key]?.isStreaming == true {
            appState.sessionStates[key]?.streamTask?.cancel()
            appState.sessionStates[key]?.flushTask?.cancel()
        }
        window = nil
        mockBackend = nil
        appState = nil
        for (key, value) in defaultsSnapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Puts the session into the state a live turn leaves it in.
    private func beginStreaming(messages: [ChatMessage] = []) {
        var state = SessionStreamState()
        state.isStreaming = true
        state.activeStreamId = UUID()
        state.messages = messages
        appState.sessionStates[sessionKey] = state
    }

    // MARK: - The default: queue

    /// Sending mid-turn queues. Steering is an override the user reaches for on
    /// the queued row, not something that happens to them on send.
    func testSendWhileStreamingQueuesAndDoesNotSteer() async {
        await mockBackend.setAcceptsSteering(true)
        beginStreaming()

        appState.enqueueMessage(text: "also check the tests", attachments: [], in: window)

        XCTAssertEqual(window.messageQueue.map(\.text), ["also check the tests"])
        let steered = await mockBackend.steeredPrompts
        XCTAssertTrue(steered.isEmpty, "Nothing reaches the agent until the user says when")
        XCTAssertTrue(appState.sessionStates[sessionKey]?.isStreaming ?? false)
    }

    // MARK: - Steering

    func testSteerQueuedMessageDeliversItIntoTheRunningTurn() async {
        await mockBackend.setAcceptsSteering(true)
        beginStreaming()
        appState.enqueueMessage(text: "queued one", attachments: [], in: window)
        appState.enqueueMessage(text: "queued two", attachments: [], in: window)
        let target = window.messageQueue[0].id

        let steered = await appState.steerQueuedMessage(id: target, in: window)

        XCTAssertTrue(steered)
        let prompts = await mockBackend.steeredPrompts
        XCTAssertEqual(prompts, ["queued one"])
        XCTAssertEqual(
            window.messageQueue.map(\.text),
            ["queued two"],
            "Only the steered message leaves the queue"
        )
    }

    /// The steered text never passes through `sendPrompt`, so nothing else
    /// would put it in the transcript — without this the user watches their
    /// message vanish while the agent silently acts on it.
    func testSteeredMessageIsAppendedToTheTranscript() async {
        await mockBackend.setAcceptsSteering(true)
        beginStreaming(messages: [ChatMessage(role: .user, content: "first")])
        appState.enqueueMessage(text: "and also this", attachments: [], in: window)

        await appState.steerQueuedMessage(id: window.messageQueue[0].id, in: window)

        let state = appState.sessionStates[sessionKey]
        XCTAssertEqual(state?.messages.map(\.content), ["first", "and also this"])
        XCTAssertEqual(state?.messages.last?.role, .user)
        XCTAssertTrue(
            state?.needsNewMessage ?? false,
            "The agent's next delta must open a new bubble rather than extend the one it was mid-way through"
        )
    }

    func testSteeringLeavesTheTurnRunning() async {
        await mockBackend.setAcceptsSteering(true)
        beginStreaming()
        let streamId = appState.sessionStates[sessionKey]?.activeStreamId
        appState.enqueueMessage(text: "keep going but also…", attachments: [], in: window)

        await appState.steerQueuedMessage(id: window.messageQueue[0].id, in: window)

        XCTAssertTrue(appState.sessionStates[sessionKey]?.isStreaming ?? false)
        XCTAssertEqual(
            appState.sessionStates[sessionKey]?.activeStreamId,
            streamId,
            "Steering must not start a new turn"
        )
    }

    func testSteerAllQueuedAsOneJoinsTheQueueIntoOneSteer() async {
        await mockBackend.setAcceptsSteering(true)
        beginStreaming()
        appState.enqueueMessage(text: "first", attachments: [], in: window)
        appState.enqueueMessage(text: "second", attachments: [], in: window)

        let steered = await appState.steerAllQueuedAsOne(in: window)

        XCTAssertTrue(steered)
        let prompts = await mockBackend.steeredPrompts
        XCTAssertEqual(prompts, ["first\n\nsecond"])
        XCTAssertTrue(window.messageQueue.isEmpty)
        XCTAssertTrue(appState.sessionStates[sessionKey]?.isStreaming ?? false)
    }

    // MARK: - When the turn won't take it

    /// A declined steer is not a lost message: it stays queued and goes out
    /// when the turn ends, exactly as if the user had never pressed anything.
    func testDeclinedSteerLeavesTheMessageQueued() async {
        await mockBackend.setAcceptsSteering(false)
        beginStreaming()
        appState.enqueueMessage(text: "handle this next", attachments: [], in: window)

        let steered = await appState.steerQueuedMessage(id: window.messageQueue[0].id, in: window)

        XCTAssertFalse(steered)
        XCTAssertEqual(window.messageQueue.map(\.text), ["handle this next"])
        let declined = await mockBackend.declinedSteerCount
        XCTAssertEqual(declined, 1, "The backend should have been asked before giving up")
        XCTAssertTrue(
            appState.sessionStates[sessionKey]?.isStreaming ?? false,
            "Failing to steer must not cancel the turn either"
        )
    }

    func testDeclinedSteerAllLeavesTheWholeQueueIntact() async {
        await mockBackend.setAcceptsSteering(false)
        beginStreaming()
        appState.enqueueMessage(text: "first", attachments: [], in: window)
        appState.enqueueMessage(text: "second", attachments: [], in: window)

        let steered = await appState.steerAllQueuedAsOne(in: window)

        XCTAssertFalse(steered)
        XCTAssertEqual(window.messageQueue.map(\.text), ["first", "second"])
    }

    /// Both transports could carry an attachment in principle, but the encoding
    /// differs per provider — so rather than risk dropping one mid-turn, a
    /// message carrying attachments stays in the queue.
    func testMessageWithAttachmentsIsNeverSteered() async {
        await mockBackend.setAcceptsSteering(true)
        beginStreaming()
        appState.enqueueMessage(
            text: "look at this",
            attachments: [Attachment(type: .image, name: "shot.png", path: "/tmp/shot.png")],
            in: window
        )

        let steered = await appState.steerQueuedMessage(id: window.messageQueue[0].id, in: window)

        XCTAssertFalse(steered)
        XCTAssertEqual(window.messageQueue.map(\.text), ["look at this"])
        XCTAssertEqual(window.messageQueue.first?.attachments.count, 1)
        let prompts = await mockBackend.steeredPrompts
        XCTAssertTrue(prompts.isEmpty, "A message with attachments must not be steered")
    }

    func testNothingIsSteeredWhenNoTurnIsRunning() async {
        await mockBackend.setAcceptsSteering(true)
        appState.sessionStates[sessionKey] = SessionStreamState()

        let steered = await appState.steerActiveStream(
            text: "hello",
            attachments: [],
            in: window
        )

        XCTAssertFalse(steered)
        let prompts = await mockBackend.steeredPrompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testBlankTextIsNeverSteered() async {
        await mockBackend.setAcceptsSteering(true)
        beginStreaming()

        let steered = await appState.steerActiveStream(text: "   \n ", attachments: [], in: window)

        XCTAssertFalse(steered)
        let prompts = await mockBackend.steeredPrompts
        XCTAssertTrue(prompts.isEmpty)
    }

    // MARK: - Offering the choice

    /// The queue UI only offers "steer now" when the transport can reach a
    /// running turn at all; ACP has no equivalent, so it gets the interrupt
    /// button instead.
    func testCanSteerFollowsTheBackendsTransport() {
        XCTAssertTrue(appState.canSteer(in: window), "The mock backend's transport supports steering")
    }
}
