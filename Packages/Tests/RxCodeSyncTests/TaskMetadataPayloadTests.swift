import Foundation
import Testing
import RxCodeCore
@testable import RxCodeSync

@Suite("Task metadata sync")
struct TaskMetadataPayloadTests {
    @Test("A metadata edit and unused catalog travel between phone and Mac")
    func roundTrip() throws {
        let projectID = UUID()
        let request = TaskBoardRequestPayload(projectID: projectID, operation: .editMetadata,
                                              metadataEdit: TaskMetadataEdit(field: .versions, name: "v2.0.0"))
        let decoded = try JSONDecoder().decode(TaskBoardRequestPayload.self, from: JSONEncoder().encode(request))
        #expect(decoded.operation == .editMetadata)
        var board = TaskBoard()
        decoded.metadataEdit?.apply(to: &board)
        let snapshot = MobileTaskBoardSnapshot(projectID: projectID, board: board)
        let received = try JSONDecoder().decode(MobileTaskBoardSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(received.board.allVersions == ["v2.0.0"])
    }

    @Test("Older requests decode without metadata")
    func legacyRequest() throws {
        let request = Data("{\"clientRequestID\":\"\(UUID().uuidString)\",\"projectID\":\"\(UUID().uuidString)\",\"operation\":\"fetch\"}".utf8)
        let decoded = try JSONDecoder().decode(TaskBoardRequestPayload.self, from: request)
        #expect(decoded.metadataEdit == nil)
    }
}
