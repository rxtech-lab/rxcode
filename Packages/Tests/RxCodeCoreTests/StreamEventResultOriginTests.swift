import Foundation
import Testing
@testable import RxCodeCore

@Suite("ResultEvent origin decoding")
struct StreamEventResultOriginTests {

    private func decode(_ json: String) throws -> StreamEvent {
        try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
    }

    @Test("result with origin.kind == task-notification is a background follow-up")
    func taskNotificationResult() throws {
        let json = """
        {"type":"result","subtype":"success","session_id":"s-1","is_error":false,"origin":{"kind":"task-notification"}}
        """
        guard case let .result(event) = try decode(json) else {
            Issue.record("expected .result")
            return
        }
        #expect(event.originKind == "task-notification")
        #expect(event.isTaskNotification == true)
    }

    @Test("result without origin is a normal end-of-turn result")
    func userTurnResult() throws {
        let json = """
        {"type":"result","subtype":"success","session_id":"s-1","is_error":false}
        """
        guard case let .result(event) = try decode(json) else {
            Issue.record("expected .result")
            return
        }
        #expect(event.originKind == nil)
        #expect(event.isTaskNotification == false)
    }

    @Test("result with a non-task-notification origin kind still ends the turn")
    func otherOriginResult() throws {
        let json = """
        {"type":"result","subtype":"success","session_id":"s-1","is_error":false,"origin":{"kind":"user"}}
        """
        guard case let .result(event) = try decode(json) else {
            Issue.record("expected .result")
            return
        }
        #expect(event.originKind == "user")
        #expect(event.isTaskNotification == false)
    }

    // MARK: - Background-task system events

    @Test("task_started exposes task_id with no status")
    func taskStarted() throws {
        let json = """
        {"type":"system","subtype":"task_started","task_id":"ba8pw5l47","task_type":"local_bash","session_id":"s-1"}
        """
        guard case let .system(event) = try decode(json) else {
            Issue.record("expected .system")
            return
        }
        #expect(event.subtype == "task_started")
        #expect(event.taskId == "ba8pw5l47")
        #expect(event.taskStatus == nil)
    }

    @Test("task_updated reads status from the nested patch")
    func taskUpdatedPatchStatus() throws {
        let json = """
        {"type":"system","subtype":"task_updated","task_id":"ba8pw5l47","patch":{"status":"completed","end_time":1783678637357},"session_id":"s-1"}
        """
        guard case let .system(event) = try decode(json) else {
            Issue.record("expected .system")
            return
        }
        #expect(event.taskId == "ba8pw5l47")
        #expect(event.taskStatus == "completed")
    }

    @Test("task_notification reads top-level status")
    func taskNotificationStatus() throws {
        let json = """
        {"type":"system","subtype":"task_notification","task_id":"ba8pw5l47","status":"completed","summary":"done","session_id":"s-1"}
        """
        guard case let .system(event) = try decode(json) else {
            Issue.record("expected .system")
            return
        }
        #expect(event.taskId == "ba8pw5l47")
        #expect(event.taskStatus == "completed")
    }

    @Test("plain status system event carries no task id")
    func plainStatusEvent() throws {
        let json = """
        {"type":"system","subtype":"status","status":"requesting","session_id":"s-1"}
        """
        guard case let .system(event) = try decode(json) else {
            Issue.record("expected .system")
            return
        }
        #expect(event.taskId == nil)
        // taskStatus decodes the top-level `status`, but with no taskId the
        // background-task tracker ignores it.
        #expect(event.taskStatus == "requesting")
    }
}
