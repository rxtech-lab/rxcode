import Foundation
import Testing
@testable import RxCodeCore

@Suite("Flowcy MCP contracts")
struct FlowcyToolTests {
    @Test func toolsAreAlwaysAvailable() throws {
        for name in [FlowcyTool.name, FlowcyTool.catalogName, "ide__get_ci_status", "ide__search_docs"] {
            let tool = try #require(IDEToolRegistry.allTools.first { $0.name == name })
            guard case .alwaysIDEOnly = tool.visibility else { Issue.record("Cloud tools must be available across backends"); continue }
        }
        #expect(Set(FlowcyTool.operations.map(\.name)).count == FlowcyTool.operations.count)
    }

    @Test func credentialOperationsCannotBeDispatched() {
        for name in ["secretsGetUserKey", "secretsGetBundle", "secretsUpsertFile", "docsCreateUploadToken", "releaseInstallToken", "projectSecretsWrite", "menuExecuteCommand"] {
            #expect(FlowcyTool.operation(name) == nil)
        }
        for name in ["secretsManage", "secretsDownload", "releaseTokenSetup"] {
            #expect(FlowcyTool.operation(name)?.mutates == true)
        }
    }

    @Test func parametersAreValidatedBeforeDispatch() throws {
        let get = try #require(FlowcyTool.operation("docsGetDocument"))
        try FlowcyTool.validate(.object(["repoId": .string("owner/repo"), "docId": .string("design/intro")]), for: get)
        #expect(throws: IDEToolError.self) { try FlowcyTool.validate(.object(["repoId": .string("owner/repo")]), for: get) }
        #expect(throws: IDEToolError.self) { try FlowcyTool.validate(.object(["repoId": .string("owner/repo"), "docId": .string("x"), "token": .string("forbidden")]), for: get) }
        let version = try #require(FlowcyTool.operation("docsVersion"))
        for number in [0.0, -1, 1.5, Double.infinity, 1e30] {
            #expect(throws: IDEToolError.self) {
                try FlowcyTool.validate(.object(["repoId": .string("r"), "docId": .string("d"), "version": .number(number)]), for: version)
            }
        }
    }

    @Test func mutationClassificationIsExplicit() throws {
        for name in ["releaseDispatch", "ciTrigger", "ciClosePR", "docsDelete", "automationSave", "cloudLink", "cloudChat"] {
            #expect(FlowcyTool.operation(name)?.mutates == true)
        }
        for name in ["docsGetDocument", "releaseDispatchHistory", "ciHistory", "cloudBoard", "trustedEmails"] {
            #expect(FlowcyTool.operation(name)?.mutates == false)
        }
    }
}
