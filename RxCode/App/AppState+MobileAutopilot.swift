import Foundation
import os
import RxAuthSwift
import RxCodeCore
import RxCodeSync
import SwiftUI

/// Desktop-side handling of mobile autopilot requests. Mobile mirrors the
/// macOS Autopilot settings tab but never calls `autopilot.rxlab.app` itself —
/// every operation arrives here as a generic `AutopilotRequestPayload`, is
/// dispatched on its `AutopilotOp`, performed with the existing autopilot /
/// secrets / docs / release / CI services (the desktop holds the rxlab token
/// and the passkey-derived secrets key), and answered with an
/// `AutopilotResultPayload` echoing the same `clientRequestID`.
extension AppState {

    func handleMobileAutopilotRequest(_ request: AutopilotRequestPayload, fromHex: String) async {
        guard let op = AutopilotOp(rawValue: request.operation) else {
            await replyAutopilot(request, fromHex: fromHex, ok: false,
                                 errorMessage: "Unknown autopilot operation \(request.operation).")
            return
        }
        do {
            let body = try await performAutopilotOperation(op, request: request)
            await replyAutopilot(request, fromHex: fromHex, ok: true, body: body)
        } catch {
            logger.error("[MobileSync] autopilot op=\(request.operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            await replyAutopilot(request, fromHex: fromHex, ok: false, errorMessage: error.localizedDescription)
        }
    }

    private func replyAutopilot(
        _ request: AutopilotRequestPayload,
        fromHex: String,
        ok: Bool,
        errorMessage: String? = nil,
        body: Data? = nil
    ) async {
        let result = AutopilotResultPayload(
            clientRequestID: request.clientRequestID,
            domain: request.domain,
            operation: request.operation,
            ok: ok,
            errorMessage: errorMessage,
            body: body
        )
        await MobileSyncService.shared.send(.autopilotResult(result), toHex: fromHex)
    }

    /// Decodes the request body as `T`, throwing a descriptive error when the
    /// body is missing for an operation that requires one.
    private func decodeAutopilotBody<T: Decodable>(_ request: AutopilotRequestPayload, as type: T.Type) throws -> T {
        guard let data = request.body else {
            throw MobileRemoteConfigError.invalidRequest("Missing request body for \(request.operation).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Optional body variant — returns nil when absent or undecodable, used by
    /// operations whose parameters are all optional (search/cursor queries).
    private func optionalAutopilotBody<T: Decodable>(_ request: AutopilotRequestPayload, as type: T.Type) -> T? {
        guard let data = request.body else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func performAutopilotOperation(_ op: AutopilotOp, request: AutopilotRequestPayload) async throws -> Data? {
        let encoder = JSONEncoder()
        switch op {

        // MARK: Account
        case .accountStatus:
            let status = AutopilotAccountStatus(
                isSignedIn: isSignedIn,
                name: rxUser?.name,
                email: rxUser?.email,
                avatarURL: rxUser?.image
            )
            return try encoder.encode(status)

        // MARK: Shared repo picker
        case .listManagedRepos:
            let q = optionalAutopilotBody(request, as: AutopilotReposQuery.self)
            let page = try await secrets.listManagedRepositories(search: q?.search, cursor: q?.cursor)
            return try encoder.encode(page)

        // MARK: Automation settings
        case .automationSchema:
            return try encoder.encode(try await automationSchema())
        case .automationValues:
            return try encoder.encode(try await automationValues())
        case .automationSave:
            let values = try decodeAutopilotBody(request, as: PreferencesValues.self)
            return try encoder.encode(try await saveAutomationValues(values.values))

        // MARK: Repo setup templates
        case .repoSetupSchema:
            return try encoder.encode(try await repoSetupSchema())
        case .repoSetupList:
            return try encoder.encode(RepoSetupTemplateList(items: try await repoSetupTemplates()))
        case .repoSetupCreate:
            let input = try decodeAutopilotBody(request, as: RepoSetupTemplateInput.self)
            return try encoder.encode(try await createRepoSetupTemplate(input))
        case .repoSetupUpdate:
            let body = try decodeAutopilotBody(request, as: AutopilotRepoSetupUpdateBody.self)
            return try encoder.encode(try await updateRepoSetupTemplate(id: body.id, body.input))
        case .repoSetupDelete:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            try await deleteRepoSetupTemplate(id: body.id)
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
        case .ciListPRs:
            let body = try decodeAutopilotBody(request, as: AutopilotIDBody.self)
            let items = try await ciUpdates.pullRequests(id: body.id)
            return try encoder.encode(CIPullRequestList(items: items))
        case .ciClosePR:
            let body = try decodeAutopilotBody(request, as: AutopilotCIClosePRBody.self)
            try await ciUpdates.closePullRequest(id: body.id, prNumber: body.prNumber)
            return nil

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
                    }
                )
            }
            return try encoder.encode(MobileReleaseWorkflowList(items: mapped))
        case .releaseDispatch:
            let body = try decodeAutopilotBody(request, as: AutopilotReleaseDispatchBody.self)
            return try encoder.encode(try await release.dispatch(repoId: body.repoId, body: body.request))
        case .releaseInstallToken:
            let body = try decodeAutopilotBody(request, as: AutopilotReleaseTokenBody.self)
            return try encoder.encode(try await release.installReleaseToken(repoId: body.repoId, value: body.value))
        }
    }
}
