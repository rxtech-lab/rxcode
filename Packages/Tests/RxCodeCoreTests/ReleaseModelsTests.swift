import Foundation
import Testing
@testable import RxCodeCore

@Suite("Release response contracts")
struct ReleaseModelsTests {
    @Test func workflowKeepsYamlContent() throws {
        // GET /api/v1/release-repositories/{id}/workflows returns raw rows including `content`.
        let data = Data(#"""
        [{"id":"w1","releaseRepositoryId":"r","workflowPath":".github/workflows/release.yml","workflowName":"Release",
          "content":"name: Release\non: workflow_dispatch\n","isSelected":true,"isReleaseWorkflow":true,
          "hasWorkflowDispatch":true,"inputs":[{"name":"version","type":"string","required":true}]}]
        """#.utf8)
        let workflow = try #require(try JSONDecoder().decode([ReleaseWorkflow].self, from: data).first)
        #expect(workflow.content == "name: Release\non: workflow_dispatch\n")
        #expect(workflow.inputs?.first?.required == true)
    }

    @Test func dispatchHistoryDecodesMixedValues() throws {
        let data = Data(#"""
        {"items":[{"id":"d1","releaseRepositoryId":"r","releaseWorkflowId":"w1","status":"failed",
          "inputValues":{"version":"1.2.0","draft":true},"branch":"main","workflowRunId":null,
          "workflowRunUrl":"https://github.com/o/r/actions","errorMessage":"Bad input",
          "triggeredAt":"2026-10-23T10:00:00.000Z","completedAt":1761213600000}],
         "pagination":{"nextCursor":null,"hasMore":false}}
        """#.utf8)
        let item = try #require(try JSONDecoder().decode(ReleaseDispatchHistoryPage.self, from: data).items.first)
        #expect(item.isFailed)
        #expect(item.inputValues?["draft"]?.description == "true")
        #expect(item.inputValues?["version"]?.description == "1.2.0")
        #expect(item.triggeredDate != nil)
        #expect(item.completedAt?.date != nil)
    }
}
