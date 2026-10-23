import Foundation
import RxCodeCore
import RxCodeSync

/// Uses the same typed contracts as the desktop while keeping secrets crypto on device.
@MainActor
final class FlowcyDirectService {
    private let autopilot = AutopilotService(rxAuth: .shared)
    private let secrets = SecretsService(rxAuth: .shared)
    private let ciUpdates = CIUpdateService(rxAuth: .shared)
    private let docs = DocsService(rxAuth: .shared)
    private let release = ReleaseService(rxAuth: .shared)

    private func decodeAutopilotBody<T: Decodable>(_ request: AutopilotRequestPayload, as type: T.Type) throws -> T {
        guard let data = request.body else { throw AutopilotRemoteError.server("Missing request body.") }
        return try JSONDecoder().decode(type, from: data)
    }
    private func optionalAutopilotBody<T: Decodable>(_ request: AutopilotRequestPayload, as type: T.Type) -> T? {
        guard let data = request.body else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func perform(_ op: AutopilotOp, request: AutopilotRequestPayload) async throws -> Data? {
        let encoder = JSONEncoder()
        switch op {
        case .listManagedRepos:
            let q = optionalAutopilotBody(request, as: AutopilotReposQuery.self)
            let page = try await secrets.listManagedRepositories(search: q?.search, cursor: q?.cursor)
            return try encoder.encode(page)
        case .installGitHubAppUrl:
            return try encoder.encode(try await autopilot.installUrl())

        // MARK: Automation settings
        case .automationSchema:
            return try encoder.encode(try await autopilot.getAutomationSchema())
        case .automationValues:
            return try encoder.encode(try await autopilot.getPreferences())
        case .automationSave:
            let values = try decodeAutopilotBody(request, as: PreferencesValues.self)
            return try encoder.encode(try await autopilot.putPreferences(values))

        // MARK: Repo setup templates
        case .repoSetupSchema:
            return try encoder.encode(try await autopilot.getRepoSetupSchema())
        case .repoSetupList:
            return try encoder.encode(try await autopilot.listSetupTemplates())
        case .repoSetupCreate:
            let input = try decodeAutopilotBody(request, as: RepoSetupTemplateInput.self)
            return try encoder.encode(try await autopilot.createSetupTemplate(input))
        case .repoSetupUpdate:
            let body = try decodeAutopilotBody(request, as: AutopilotRepoSetupUpdateBody.self)
            return try encoder.encode(try await autopilot.updateSetupTemplate(id: body.id, body.input))
        case .repoSetupDelete:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            try await autopilot.deleteSetupTemplate(id: body.id)
            return nil

        // MARK: Secrets — the desktop only relays opaque ciphertext; the phone
        // derives the KEK from the synced passkey and does all crypto on-device.
        case .secretsEnrollmentStatus:
            let key = try await secrets.getUserKey()
            return try encoder.encode(AutopilotSecretsEnrollment(enrolled: key.enrolled))
        case .secretsGetUserKey:
            return try encoder.encode(try await secrets.getUserKey())
        case .secretsListEnvironments:
            let body = try decodeAutopilotBody(request, as: AutopilotSecretsRepoBody.self)
            return try encoder.encode(try await secrets.listEnvironments(repo: body.repo))
        case .secretsCreateEnvironment:
            let body = try decodeAutopilotBody(request, as: AutopilotSecretsCreateEnvBody.self)
            _ = try await secrets.createEnvironment(repo: body.repo, body: body.body)
            return nil
        case .secretsDeleteEnvironment:
            let body = try decodeAutopilotBody(request, as: AutopilotSecretsEnvRefBody.self)
            try await secrets.deleteEnvironment(repo: body.repo, envId: body.envId)
            return nil
        case .secretsListFiles:
            let body = try decodeAutopilotBody(request, as: AutopilotSecretsEnvRefBody.self)
            return try encoder.encode(try await secrets.listFiles(repo: body.repo, envId: body.envId))
        case .secretsGetBundle:
            let body = try decodeAutopilotBody(request, as: AutopilotSecretsEnvRefBody.self)
            return try encoder.encode(try await secrets.bundle(repo: body.repo, env: body.envId))
        case .secretsUpsertFile:
            let body = try decodeAutopilotBody(request, as: AutopilotSecretsUpsertFileBody.self)
            _ = try await secrets.upsertFile(repo: body.repo, envId: body.envId, body: body.file)
            return nil
        case .secretsDeleteFile:
            let body = try decodeAutopilotBody(request, as: AutopilotSecretsDeleteFileBody.self)
            try await secrets.deleteFile(repo: body.repo, envId: body.envId, fileId: body.fileId)
            return nil

        // MARK: CI auto-update
        case .ciList:
            let q = optionalAutopilotBody(request, as: AutopilotCursorQuery.self)
            return try encoder.encode(try await ciUpdates.listWatchedRepositories(cursor: q?.cursor))
        case .ciOverview:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            return try encoder.encode(try await ciUpdates.overview(repository: body.id))
        case .ciAdd:
            let body = try decodeAutopilotBody(request, as: AddWatchedRepoBody.self)
            _ = try await ciUpdates.addWatchedRepository(body)
            return nil
        case .ciUpdateFrequency:
            let body = try decodeAutopilotBody(request, as: AutopilotCIFrequencyBody.self)
            try await ciUpdates.updateScanFrequency(id: body.id, frequency: body.frequency)
            return nil
        case .ciDelete:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            try await ciUpdates.deleteWatchedRepository(id: body.id)
            return nil
        case .ciHistory:
            let body = try decodeAutopilotBody(request, as: AutopilotCIHistoryBody.self)
            let items = try await ciUpdates.history(id: body.id, limit: body.limit)
            return try encoder.encode(CIUpdateRunHistoryList(items: items))
        case .ciTrigger:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            return try encoder.encode(try await ciUpdates.trigger(id: body.id))
        case .ciTriggerDependencies:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            return try encoder.encode(try await ciUpdates.triggerDependencies(id: body.id))
        case .ciListPRs:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            let items = try await ciUpdates.pullRequests(id: body.id)
            return try encoder.encode(CIPullRequestList(items: items))
        case .ciClosePR:
            let body = try decodeAutopilotBody(request, as: AutopilotCIClosePRBody.self)
            try await ciUpdates.closePullRequest(id: body.id, prNumber: body.prNumber)
            return nil

        case .ciAutomationGet:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            return try encoder.encode(try await ciUpdates.automation(id: body.id))
        case .ciAutomationSave:
            let body = try decodeAutopilotBody(request, as: AutopilotCIAutomationSaveBody.self)
            return try encoder.encode(RepositoryAutomationSaveResponse(settings: try await ciUpdates.saveAutomation(id: body.id, settings: body.settings)))
        case .ciDirectories:
            let body = try decodeAutopilotBody(request, as: AutopilotCIDirectoriesBody.self)
            return try encoder.encode(try await ciUpdates.directories(id: body.id, sha: body.sha))

        // MARK: Docs
        case .docsList:
            let q = optionalAutopilotBody(request, as: AutopilotReposQuery.self)
            return try encoder.encode(try await docs.listRepositories(search: q?.search, cursor: q?.cursor))
        case .docsAdd:
            let body = try decodeAutopilotBody(request, as: AddDocsRepoBody.self)
            _ = try await docs.addRepository(body)
            return nil
        case .docsDelete:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            try await docs.deleteRepository(id: body.id)
            return nil
        case .docsListDocuments:
            let body = try decodeAutopilotBody(request, as: AutopilotDocsListDocumentsBody.self)
            return try encoder.encode(try await docs.listDocuments(repoId: body.repoId, cursor: body.cursor))
        case .docsGetDocument:
            let body = try decodeAutopilotBody(request, as: AutopilotDocsDocBody.self)
            return try encoder.encode(try await docs.getDocument(repoId: body.repoId, docId: body.docId))
        case .docsUploadDocument:
            let body = try decodeAutopilotBody(request, as: AutopilotDocsUploadBody.self)
            let result = try await docs.uploadDocuments(
                repoId: body.repoId,
                documents: [DocsDocumentUpload(docId: body.docId, content: body.content, originalLink: body.originalLink)]
            )
            return try encoder.encode(result)
        case .docsDeleteDocument:
            let body = try decodeAutopilotBody(request, as: AutopilotDocsDocBody.self)
            try await docs.deleteDocument(repoId: body.repoId, docId: body.docId)
            return nil
        case .docsCreateUploadToken:
            let body = try decodeAutopilotBody(request, as: AutopilotDocsCreateTokenBody.self)
            return try encoder.encode(try await docs.createUploadToken(repoId: body.repoId, name: body.name))
        case .docsInstallGithubSecret:
            let body = try decodeAutopilotBody(request, as: AutopilotRepoIDBody.self)
            return try encoder.encode(try await docs.installGithubSecret(repoId: body.repoId))

        // MARK: Release
        case .releaseList:
            let q = optionalAutopilotBody(request, as: AutopilotCursorQuery.self)
            return try encoder.encode(try await release.listRepositories(cursor: q?.cursor))
        case .releaseAdd:
            let body = try decodeAutopilotBody(request, as: AddReleaseRepoBody.self)
            _ = try await release.addRepository(body)
            return nil
        case .releaseDelete:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            try await release.deleteRepository(id: body.id)
            return nil
        case .releaseBranches:
            let body = try decodeAutopilotBody(request, as: AutopilotRepoIDBody.self)
            return try encoder.encode(ReleaseBranchList(items: try await release.branches(repoId: body.repoId)))
        case .releaseDispatchHistory:
            let body = try decodeAutopilotBody(request, as: AutopilotRepoIDBody.self)
            return try encoder.encode(try await release.dispatchHistory(repoId: body.repoId))
        case .releaseRescanWorkflows:
            let body = try decodeAutopilotBody(request, as: AutopilotRepoIDBody.self)
            return try encoder.encode(try await release.rescanWorkflows(repoId: body.repoId))
        case .releaseSetWorkflowSelected:
            let body = try decodeAutopilotBody(request, as: AutopilotReleaseWorkflowSelectionBody.self)
            try await release.setWorkflowSelected(repoId: body.repoId, workflowId: body.workflowId, isSelected: body.isSelected)
            return nil
        case .releaseListWorkflows:
            let body = try decodeAutopilotBody(request, as: AutopilotRepoIDBody.self)
            let workflows = try await release.listWorkflows(repoId: body.repoId)
            let mapped = workflows.map { workflow in
                MobileReleaseWorkflow(
                    id: workflow.id,
                    workflowPath: workflow.workflowPath,
                    workflowName: workflow.workflowName,
                    isSelected: workflow.isSelected,
                    isReleaseWorkflow: workflow.isReleaseWorkflow,
                    hasWorkflowDispatch: workflow.hasWorkflowDispatch,
                    inputs: workflow.inputs?.map { input in
                        MobileReleaseWorkflowInput(
                            name: input.name,
                            type: input.type,
                            description: input.description,
                            required: input.required,
                            defaultString: input.defaultString,
                            defaultBool: input.defaultBool,
                            options: input.options
                        )
                    },
                    content: workflow.content
                )
            }
            return try encoder.encode(MobileReleaseWorkflowList(items: mapped))
        case .releaseDispatch:
            let body = try decodeAutopilotBody(request, as: AutopilotReleaseDispatchBody.self)
            return try encoder.encode(try await release.dispatch(repoId: body.repoId, body: body.request))
        case .releaseInstallToken:
            let body = try decodeAutopilotBody(request, as: AutopilotReleaseTokenBody.self)
            return try encoder.encode(try await release.installReleaseToken(repoId: body.repoId, value: body.value))

        default:
            throw AutopilotRemoteError.server("This operation requires a remote workspace.")
        }
    }
}
