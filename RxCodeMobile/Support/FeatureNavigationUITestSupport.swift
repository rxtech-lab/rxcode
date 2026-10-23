#if DEBUG
import Foundation
import RxCodeCore
import RxCodeSync

/// UI-only fixtures: navigation tests do not authenticate or mutate a live repository.
enum FeatureNavigationUITestSupport {
    static func response(_ op: AutopilotOp) throws -> Data {
        let encoder = JSONEncoder()
        switch op {
        case .ciOverview:
            return Data(#"{"repository":{"id":"watched","installationId":1,"repositoryId":1,"repositoryFullName":"rxtech-lab/rxcode"},"history":[],"pullRequests":[],"automation":null,"errors":{"automation":"Automation is unavailable on this Flowcy server. Update the service, then try again. CI history and pull requests remain available."}}"#.utf8)
        case .ciList:
            return try encoder.encode(WatchedRepoPage(repositories: [
                WatchedRepo(id: "watched", installationId: 1, repositoryId: 1,
                            repositoryFullName: "rxtech-lab/rxcode")
            ]))
        case .ciHistory, .ciListPRs, .releaseDispatchHistory, .releaseBranches:
            return Data(#"{"items":[]}"#.utf8)
        case .ciAutomationGet:
            throw CIUpdateService.ServiceError.apiError(404, "")
        case .releaseList:
            return Data(#"{"items":[{"id":"release","repositoryFullName":"rxtech-lab/rxcode"}]}"#.utf8)
        case .releaseListWorkflows:
            return try encoder.encode(MobileReleaseWorkflowList(items: [
                MobileReleaseWorkflow(id: "workflow", workflowPath: ".github/workflows/release.yml",
                                      workflowName: "Publish App", isSelected: true,
                                      hasWorkflowDispatch: true, content: "name: Publish App\non: workflow_dispatch\n")
            ]))
        default:
            throw AutopilotRemoteError.server("Unsupported navigation fixture: \(op.rawValue)")
        }
    }
}
#endif
