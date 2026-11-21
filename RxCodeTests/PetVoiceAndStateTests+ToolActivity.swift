import AVFoundation
import Foundation
import RxAgentVoice
import RxAgentCore
import Testing
@testable import RxCode
import RxCodeCore

extension PetVoiceAndStateTests {
    @Test("Slow tool audio leaves the main actor responsive and preserves cue order", .timeLimit(.minutes(1)))
    @MainActor
    func toolAudioDoesNotBlockPet() async throws {
        let controller = PetController()
        let gate = DispatchSemaphore(value: 0)
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (commands, results) = AsyncStream<[Bool]>.makeStream()
        let player = PetToolSoundPlayer { running, finished in
            #expect(!Thread.isMainThread)
            if running {
                startSignal.yield(())
                // The main actor must remain free to process completion and release us.
                // Allow loaded CI runners to schedule the main-actor continuation.
                // A synchronous playback regression still fails within the test's limit.
                let released = gate.wait(timeout: .now() + 30)
                #expect(released == .success)
            }
            results.yield([running, finished])
        }
        player.update(isRunning: true, didFinish: false)
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        defer { gate.signal() }

        controller.toolSounds = player
        controller.handlePetToolEvent(.toolCallStarted(id: "slow-audio", name: "Read"))
        controller.handlePetToolEvent(.toolCallResult(id: "slow-audio", content: "done", isError: false))
        #expect(controller.toolActivity.pending.isEmpty)
        #expect(controller.toolActivity.calls.first?.status == .completed)
        player.update(isRunning: false, didFinish: true)
        controller.hidePreviousToolCalls()
        #expect(controller.toolActivity.calls.isEmpty)
        gate.signal()

        var iterator = commands.makeAsyncIterator()
        #expect(await iterator.next() == [true, false])
        // Activity cues are separate from the connection sound's loop and completion sound.
        #expect(await iterator.next() == [false, true])
    }

    @Test("Tool cues honor enabled, mute and speech gates")
    func toolCuePolicy() throws {
        #expect(PetController.permitsToolSound(enabled: true, muted: false, speaking: false))
        #expect(!PetController.permitsToolSound(enabled: false, muted: false, speaking: false))
        #expect(!PetController.permitsToolSound(enabled: true, muted: true, speaking: false))
        #expect(!PetController.permitsToolSound(enabled: true, muted: false, speaking: true))
        var config = PetConfiguration()
        #expect(config.playsToolSounds)
        config.toolSoundsEnabled = false
        let decoded = try JSONDecoder().decode(PetConfiguration.self, from: JSONEncoder().encode(config))
        #expect(!decoded.playsToolSounds)
    }

    @Test("Realtime MCP activity takes the same pet tool lifecycle as pipeline activity")
    @MainActor
    func realtimeToolActivity() {
        let item: RxAgentCore.JSONValue = .object([
            "id": .string("realtime-mcp"), "type": .string("mcpToolCall"),
            "tool": .string("external_search")
        ])
        let controller = PetController()
        let label = PetCodexRealtimeEngine.describeToolItem(item)
        #expect(label == "Using external search")
        let params: RxAgentCore.JSONValue = .object(["item": item])
        let start = PetCodexRealtimeEngine.toolEvent(method: "item/started", params: params)
        controller.handlePetToolEvent(start)
        controller.handlePetToolEvent(start)
        #expect(controller.toolActivity.pending.count == 1)
        #expect(controller.activeToolDescription == label)
        controller.handlePetToolEvent(PetCodexRealtimeEngine.toolEvent(method: "item/completed", params: params))
        #expect(controller.toolActivity.pending.isEmpty)
        #expect(controller.activeToolDescription == nil)
        #expect(controller.toolActivity.calls.first?.status == .completed)
        #expect(controller.toolSoundTask == nil)
    }

    @Test("IDE tool activity is visible before execution and survives realtime turn completion")
    @MainActor
    func immediateIDEToolActivity() async throws {
        let controller = PetController()
        let result = try await controller.withRealtimeIDEToolActivity(name: "ide__get_threads") {
            #expect(controller.toolActivity.calls.count == 1)
            #expect(controller.toolActivity.calls.first?.status == .running)
            #expect(controller.activeToolDescription == "Using get threads")
            #expect(controller.petState.status == .working)
            controller.handlePetToolEvent(.turnEnded(TurnResult()))
            await Task.yield()
            #expect(controller.toolActivity.pending.count == 1)
            return .object(["isError": .bool(false)])
        }
        #expect(result["isError"] == RxCodeCore.JSONValue.bool(false))
        #expect(controller.toolActivity.calls.first?.status == .completed)
        #expect(controller.toolActivity.pending.isEmpty)
    }

    @Test("IDE error responses mark the immediate activity as failed")
    @MainActor
    func immediateIDEToolErrorResponse() async throws {
        let controller = PetController()
        _ = try await controller.withRealtimeIDEToolActivity(name: "ide__get_threads") {
            .object(["isError": .bool(true)])
        }
        #expect(controller.toolActivity.calls.first?.status == .failed)
        #expect(controller.toolActivity.pending.isEmpty)
    }

    @Test("IDE tool execution failures settle the immediate activity")
    @MainActor
    func immediateIDEToolFailure() async {
        enum Failure: Error { case failed }
        let controller = PetController()
        do {
            _ = try await controller.withRealtimeIDEToolActivity(name: "ide__get_threads") {
                throw Failure.failed
            }
            Issue.record("Expected tool failure")
        } catch {}
        #expect(controller.toolActivity.calls.first?.status == .failed)
        #expect(controller.toolActivity.pending.isEmpty)
    }

    @Test("Late realtime IDE notifications do not duplicate execution activity")
    func realtimeIDENotifications() {
        for tool in ["ide__get_threads", "mcp__rxcode_ide__ide__get_threads"] {
            let params: RxAgentCore.JSONValue = .object(["item": .object([
                "id": .string("late-item"), "type": .string("mcpToolCall"), "tool": .string(tool)
            ])])
            #expect(PetCodexRealtimeEngine.toolEvent(method: "item/started", params: params) == nil)
            #expect(PetCodexRealtimeEngine.toolEvent(method: "item/completed", params: params) == nil)
        }
    }

    @Test("Realtime tool labels are formatted once in pet bubbles")
    @MainActor
    func petToolLabels() {
        let raw = "mcp__rxcode_ide__ide__get_projects"
        let label = PetCodexRealtimeConnectionFriendlyTool.describe(raw)
        #expect(label == "Using get projects")
        #expect(PetCodexRealtimeConnectionFriendlyTool.describe(label) == label)
        let controller = PetController()
        controller.handlePetToolEvent(.toolCallStarted(id: "realtime", name: label))
        #expect(controller.toolActivity.calls.first?.name == label)
        controller.handlePetToolEvent(.toolCallStarted(id: "pipeline", name: raw))
        #expect(controller.toolActivity.calls.last?.name == label)
        #expect(PetCodexRealtimeConnectionFriendlyTool.describe("Running swift build") == "Running swift build")
        controller.handlePetToolEvent(nil)
    }


    @Test("Finished pet tools expire independently after thirty seconds")
    func petToolExpiration() {
        var activity = PetToolActivity()
        let start = Date(timeIntervalSince1970: 1_000)
        activity.start(id: "done", name: "Read")
        activity.start(id: "failed", name: "Search")
        activity.start(id: "running", name: "Build")
        let completed = activity.finish(id: "done", isError: false, now: start)
        let failed = activity.finish(id: "failed", isError: true, now: start.addingTimeInterval(10))
        #expect(completed)
        #expect(failed)
        activity.removeExpiredCalls(now: start.addingTimeInterval(29))
        #expect(activity.calls.count == 3)
        activity.removeExpiredCalls(now: start.addingTimeInterval(30))
        #expect(activity.calls.map(\.id) == ["failed", "running"])
        #expect(activity.nextExpiration == start.addingTimeInterval(40))
        activity.removeExpiredCalls(now: start.addingTimeInterval(40))
        #expect(activity.calls.map(\.id) == ["running"])
        #expect(activity.pending["running"] != nil)
        activity.cancelPending(now: start.addingTimeInterval(50))
        activity.cancelPending(now: start.addingTimeInterval(60))
        activity.removeExpiredCalls(now: start.addingTimeInterval(80))
        #expect(activity.calls.isEmpty)
        #expect(activity.nextExpiration == nil)
    }

    @Test("Realtime permission grants require confirmation and apply only to the requested turn")
    func realtimePermissionResponses() async {
        let params: RxAgentCore.JSONValue = .object([
            "permissions": .object(["network": .object(["enabled": .bool(true)])])
        ])
        let granted = await PetCodexRealtimeEngine.approvalResponse(
            method: "item/permissions/requestApproval", params: params, requestApproval: { _ in true }
        )
        #expect(granted?["permissions"] == params["permissions"])
        #expect(granted?["scope"]?.stringValue == "turn")
        let denied = await PetCodexRealtimeEngine.approvalResponse(
            method: "item/permissions/requestApproval", params: params, requestApproval: { _ in false }
        )
        #expect(denied?["permissions"] == .object([:]))
        let command = await PetCodexRealtimeEngine.approvalResponse(
            method: "item/commandExecution/requestApproval", params: params, requestApproval: { _ in false }
        )
        #expect(command?["decision"]?.stringValue == "reject")
        let unsupported = await PetCodexRealtimeEngine.approvalResponse(
            method: "unknown", params: params, requestApproval: { _ in true }
        )
        #expect(unsupported == nil)
    }

    @Test("Pet tool bubbles use FIFO and retain pending calls after eviction")
    func petToolFIFO() {
        var activity = PetToolActivity()
        for index in 1...4 { activity.start(id: "\(index)", name: "Tool \(index)") }
        #expect(activity.calls.map(\.id) == ["2", "3", "4"])
        #expect(activity.pending.count == 4)
        activity.start(id: "4", name: "Duplicate")
        #expect(activity.calls.count == 3)
        let evictedFinished = activity.finish(id: "1", isError: false)
        let duplicateFinished = activity.finish(id: "1", isError: false)
        let failedFinished = activity.finish(id: "3", isError: true)
        #expect(evictedFinished)
        #expect(!duplicateFinished)
        #expect(failedFinished)
        #expect(activity.calls[1].status == .failed)
        #expect(activity.calls[0].status == .running)
        let lastFinished = activity.finish(id: "4", isError: false)
        #expect(lastFinished)
        #expect(activity.calls[2].status == .completed)
        activity.cancelPending()
        #expect(activity.pending.isEmpty)
        #expect(activity.calls[0].status == .cancelled)
        #expect(activity.calls[2].status == .completed)
    }

    @Test("New questions hide previous tool bubbles without losing in-flight results")
    func hidePreviousToolCalls() {
        var activity = PetToolActivity()
        activity.start(id: "old", name: "Search")
        activity.hideCalls()
        #expect(activity.calls.isEmpty)
        #expect(activity.pending.count == 1)
        activity.start(id: "new", name: "Read")
        let oldFinished = activity.finish(id: "old", isError: false)
        #expect(oldFinished)
        #expect(activity.calls.map(\.id) == ["new"])
        #expect(activity.pending.count == 1)
    }

    @Test("A new question hides active tool status and late results keep it hidden")
    @MainActor
    func hideActiveToolStatus() {
        let controller = PetController()
        controller.handlePetToolEvent(.toolCallStarted(id: "a", name: "Search"))
        controller.handlePetToolEvent(.toolCallStarted(id: "b", name: "Read"))
        controller.hidePreviousToolCalls()
        #expect(controller.activeToolDescription == nil)
        controller.handlePetToolEvent(.toolCallResult(id: "a", content: "done", isError: false))
        #expect(controller.activeToolDescription == nil)
        #expect(controller.toolActivity.calls.isEmpty)
        #expect(controller.toolActivity.pending.count == 1)
        controller.handlePetToolEvent(nil)
    }

    @Test("Pet tool events keep overlapping calls active and stop on cancellation")
    @MainActor
    func petToolEventLifecycle() {
        let controller = PetController()
        controller.handlePetToolEvent(.toolCallStarted(id: "a", name: "Read"))
        controller.handlePetToolEvent(.toolCallStarted(id: "b", name: "Search"))
        controller.handlePetToolEvent(.toolCallResult(id: "a", content: "done", isError: false))
        #expect(controller.toolActivity.pending.count == 1)
        #expect(controller.activeToolDescription != nil)
        #expect(controller.toolActivity.calls[0].status == .completed)
        #expect(controller.toolActivity.calls[1].status == .running)
        controller.handlePetToolEvent(nil)
        #expect(controller.toolActivity.pending.isEmpty)
        #expect(controller.activeToolDescription == nil)
        #expect(controller.toolActivity.calls[1].status == .cancelled)
    }
}
