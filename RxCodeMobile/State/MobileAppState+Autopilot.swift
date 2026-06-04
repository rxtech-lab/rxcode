import CryptoKit
import Foundation
import RxCodeCore
import RxCodeSync

/// Errors surfaced by the autopilot remote-call layer.
enum AutopilotRemoteError: LocalizedError {
    case notPaired
    case timedOut
    case desktopChanged
    case server(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notPaired:
            return String(localized: "Connect an online Mac to use Autopilot.")
        case .timedOut:
            return String(localized: "Request timed out. Check your Mac and try again.")
        case .desktopChanged:
            return String(localized: "The paired Mac changed before the request finished.")
        case .server(let message):
            return message
        case .emptyResponse:
            return String(localized: "The Mac returned an empty response.")
        }
    }
}

extension MobileAppState {
    // MARK: - Generic autopilot round trip

    /// Sends one autopilot operation to the active desktop and awaits its
    /// reply, correlated by `clientRequestID`. Throws `AutopilotRemoteError`
    /// when not paired, on timeout, on desktop switch, or when the desktop
    /// reports failure.
    private func autopilotCall(
        _ domain: AutopilotDomain,
        _ op: AutopilotOp,
        bodyData: Data?
    ) async throws -> AutopilotResultPayload {
        guard isPaired else { throw AutopilotRemoteError.notPaired }
        let payload = AutopilotRequestPayload(domain: domain, operation: op, body: bodyData)
        let desktop = pairedDesktopPubkey
        return try await withCheckedThrowingContinuation { continuation in
            pendingAutopilotRequests[payload.clientRequestID] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.send(.autopilotRequest(payload), toHex: desktop)
                    self.scheduleTimeout(Self.autopilotTimeout) { state in
                        if let pending = state.pendingAutopilotRequests.removeValue(forKey: payload.clientRequestID) {
                            pending.resume(throwing: AutopilotRemoteError.timedOut)
                        }
                    }
                } catch {
                    if let pending = self.pendingAutopilotRequests.removeValue(forKey: payload.clientRequestID) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Autopilot requests can scan workflows / mint GitHub secrets on the
    /// desktop, so they get a longer ceiling than the snappy config calls.
    static let autopilotTimeout: Duration = .seconds(45)

    /// Send with an encodable body and decode a typed response.
    func autopilotSend<Req: Encodable, Res: Decodable>(
        _ domain: AutopilotDomain,
        _ op: AutopilotOp,
        body: Req,
        as: Res.Type
    ) async throws -> Res {
        let data = try JSONEncoder().encode(body)
        return try await decodeResult(await autopilotCall(domain, op, bodyData: data), as: Res.self)
    }

    /// Send with no body and decode a typed response.
    func autopilotSend<Res: Decodable>(
        _ domain: AutopilotDomain,
        _ op: AutopilotOp,
        as: Res.Type
    ) async throws -> Res {
        try await decodeResult(await autopilotCall(domain, op, bodyData: nil), as: Res.self)
    }

    /// Send with an encodable body and ignore the (empty) response.
    func autopilotSendVoid<Req: Encodable>(
        _ domain: AutopilotDomain,
        _ op: AutopilotOp,
        body: Req
    ) async throws {
        let data = try JSONEncoder().encode(body)
        try checkResult(await autopilotCall(domain, op, bodyData: data))
    }

    /// Send with no body and ignore the (empty) response.
    func autopilotSendVoid(_ domain: AutopilotDomain, _ op: AutopilotOp) async throws {
        try checkResult(await autopilotCall(domain, op, bodyData: nil))
    }

    private func decodeResult<Res: Decodable>(_ result: AutopilotResultPayload, as: Res.Type) throws -> Res {
        try checkResult(result)
        guard let body = result.body else { throw AutopilotRemoteError.emptyResponse }
        return try JSONDecoder().decode(Res.self, from: body)
    }

    private func checkResult(_ result: AutopilotResultPayload) throws {
        guard result.ok else {
            throw AutopilotRemoteError.server(result.errorMessage ?? String(localized: "The Mac could not complete the request."))
        }
    }

    // MARK: - Account

    @discardableResult
    func loadAutopilotAccount() async throws -> AutopilotAccountStatus {
        let status = try await autopilotSend(.account, .accountStatus, as: AutopilotAccountStatus.self)
        autopilotAccount = status
        return status
    }

    // MARK: - Shared repo picker

    func listAutopilotRepos(search: String?, cursor: String? = nil) async throws -> SecretsManagedRepoPage {
        try await autopilotSend(.account, .listManagedRepos,
                                body: AutopilotReposQuery(search: search, cursor: cursor),
                                as: SecretsManagedRepoPage.self)
    }

    @discardableResult
    func cloneAutopilotRepo(_ repo: SecretsManagedRepo) async throws -> Project {
        let result = try await autopilotSend(.account, .cloneManagedRepo,
                                             body: AutopilotCloneRepoBody(fullName: repo.fullName),
                                             as: AutopilotCloneRepoResult.self)
        if !projects.contains(where: { $0.id == result.project.id }) {
            projects.append(result.project)
        }
        lastCreatedProjectID = result.project.id
        Task { await requestSnapshot() }
        return result.project
    }

    func githubAppInstallURL() async throws -> URL {
        let response = try await autopilotSend(.account, .installGitHubAppUrl, as: AutopilotInstallUrlResponse.self)
        guard let url = URL(string: response.url) else {
            throw AutopilotRemoteError.server(String(localized: "The Mac returned an invalid GitHub App install URL."))
        }
        return url
    }

    // MARK: - Automation settings

    func automationSchema() async throws -> SchemaEnvelope {
        try await autopilotSend(.automation, .automationSchema, as: SchemaEnvelope.self)
    }

    func automationValues() async throws -> PreferencesValues {
        try await autopilotSend(.automation, .automationValues, as: PreferencesValues.self)
    }

    @discardableResult
    func saveAutomationValues(_ values: JSONValue) async throws -> PreferencesValues {
        try await autopilotSend(.automation, .automationSave,
                                body: PreferencesValues(values: values),
                                as: PreferencesValues.self)
    }

    // MARK: - Repo setup templates

    func repoSetupSchema() async throws -> SchemaEnvelope {
        try await autopilotSend(.repoSetup, .repoSetupSchema, as: SchemaEnvelope.self)
    }

    func repoSetupTemplates() async throws -> [RepoSetupTemplate] {
        try await autopilotSend(.repoSetup, .repoSetupList, as: RepoSetupTemplateList.self).items
    }

    @discardableResult
    func createRepoSetupTemplate(_ input: RepoSetupTemplateInput) async throws -> RepoSetupTemplate {
        try await autopilotSend(.repoSetup, .repoSetupCreate, body: input, as: RepoSetupTemplate.self)
    }

    @discardableResult
    func updateRepoSetupTemplate(id: String, _ input: RepoSetupTemplateInput) async throws -> RepoSetupTemplate {
        try await autopilotSend(.repoSetup, .repoSetupUpdate,
                                body: AutopilotRepoSetupUpdateBody(id: id, input: input),
                                as: RepoSetupTemplate.self)
    }

    func deleteRepoSetupTemplate(id: String) async throws {
        try await autopilotSendVoid(.repoSetup, .repoSetupDelete, body: AutopilotIDBody(id: id))
    }

    // MARK: - Secrets (on-device passkey crypto)
    //
    // The desktop only relays opaque ciphertext. The phone derives the KEK from
    // the iCloud-synced `rxlab.app` passkey (WebAuthn PRF) — the same credential
    // and salt the Mac uses, so the KEK is identical — and does every
    // encryption/decryption locally. Plaintext never crosses the relay.

    func secretsEnrollmentStatus() async throws -> Bool {
        try await autopilotSend(.secrets, .secretsEnrollmentStatus, as: AutopilotSecretsEnrollment.self).enrolled
    }

    private func secretsUserKey() async throws -> SecretsUserKey {
        try await autopilotSend(.secrets, .secretsGetUserKey, as: SecretsUserKey.self)
    }

    private func secretsBundle(repo: String, envId: String) async throws -> SecretsBundle {
        try await autopilotSend(.secrets, .secretsGetBundle,
                                body: AutopilotSecretsEnvRefBody(repo: repo, envId: envId),
                                as: SecretsBundle.self)
    }

    func listSecretEnvironments(repo: String) async throws -> [SecretsEnvironment] {
        try await autopilotSend(.secrets, .secretsListEnvironments,
                                body: AutopilotSecretsRepoBody(repo: repo),
                                as: SecretsEnvironmentList.self).items
    }

    /// Builds the owner environment key on-device (a fresh DEK wrapped under the
    /// passkey-derived KEK), then asks the desktop to POST it.
    func createSecretEnvironment(repo: String, name: String) async throws {
        let kek = try await secretsKeyVault.kek()
        let owner = try SecretsFlows.buildOwnerEnvironmentKey(kek: kek)
        try await autopilotSendVoid(.secrets, .secretsCreateEnvironment,
                                    body: AutopilotSecretsCreateEnvBody(
                                        repo: repo,
                                        body: CreateEnvironmentBody(name: name, ownerKey: owner.body)))
    }

    func deleteSecretEnvironment(repo: String, envId: String) async throws {
        try await autopilotSendVoid(.secrets, .secretsDeleteEnvironment,
                                    body: AutopilotSecretsEnvRefBody(repo: repo, envId: envId))
    }

    func listSecretFiles(repo: String, envId: String) async throws -> [SecretsFileMeta] {
        try await autopilotSend(.secrets, .secretsListFiles,
                                body: AutopilotSecretsEnvRefBody(repo: repo, envId: envId),
                                as: SecretsFileList.self).items
    }

    /// Resolves the environment DEK on-device: derive the KEK from the passkey
    /// and unwrap the DEK (unwrapping the user's private key first for
    /// HPKE-shared environments).
    private func resolveSecretsDEK(repo: String, envId: String) async throws -> (dek: SymmetricKey, bundle: SecretsBundle) {
        let kek = try await secretsKeyVault.kek()
        let bundle = try await secretsBundle(repo: repo, envId: envId)
        var userPrivateKey: P256.KeyAgreement.PrivateKey?
        if bundle.environmentKey.wrapMode == "hpke" {
            let userKey = try await secretsUserKey()
            userPrivateKey = try SecretsFlows.unwrapUserPrivateKey(userKey, kek: kek)
        }
        let dek = try SecretsFlows.unwrapDEK(envKey: bundle.environmentKey, kek: kek, userPrivateKey: userPrivateKey)
        return (dek, bundle)
    }

    func secretEnvironmentPlaintext(repo: String, envId: String) async throws -> [AutopilotSecretFilePlaintext] {
        let (dek, bundle) = try await resolveSecretsDEK(repo: repo, envId: envId)
        return try bundle.files.map { file in
            AutopilotSecretFilePlaintext(
                filename: file.filename,
                content: try SecretsCrypto.decryptFile(ciphertextB64: file.ciphertext, ivB64: file.iv, dek: dek)
            )
        }
    }

    func upsertSecretFile(repo: String, envId: String, filename: String, content: String) async throws {
        let (dek, _) = try await resolveSecretsDEK(repo: repo, envId: envId)
        let enc = try SecretsCrypto.encryptFile(plaintext: content, dek: dek)
        let file = UpsertFileBody(filename: filename, ciphertext: enc.ciphertext, iv: enc.iv, size: enc.size)
        try await autopilotSendVoid(.secrets, .secretsUpsertFile,
                                    body: AutopilotSecretsUpsertFileBody(repo: repo, envId: envId, file: file))
    }

    func deleteSecretFile(repo: String, envId: String, fileId: String) async throws {
        try await autopilotSendVoid(.secrets, .secretsDeleteFile,
                                    body: AutopilotSecretsDeleteFileBody(repo: repo, envId: envId, fileId: fileId))
    }

    // MARK: - CI auto-update

    func listWatchedRepos(cursor: String? = nil) async throws -> WatchedRepoPage {
        try await autopilotSend(.ciUpdates, .ciList, body: AutopilotCursorQuery(cursor: cursor), as: WatchedRepoPage.self)
    }

    func addWatchedRepo(_ body: AddWatchedRepoBody) async throws {
        try await autopilotSendVoid(.ciUpdates, .ciAdd, body: body)
    }

    func updateWatchedRepoFrequency(id: String, frequency: CIScanFrequency) async throws {
        try await autopilotSendVoid(.ciUpdates, .ciUpdateFrequency, body: AutopilotCIFrequencyBody(id: id, frequency: frequency))
    }

    func deleteWatchedRepo(id: String) async throws {
        try await autopilotSendVoid(.ciUpdates, .ciDelete, body: AutopilotIDBody(id: id))
    }

    func watchedRepoHistory(id: String, limit: Int? = nil) async throws -> [CIUpdateRunHistory] {
        try await autopilotSend(.ciUpdates, .ciHistory, body: AutopilotCIHistoryBody(id: id, limit: limit), as: CIUpdateRunHistoryList.self).items
    }

    func triggerWatchedRepoScan(id: String) async throws -> CITriggerResponse {
        try await autopilotSend(.ciUpdates, .ciTrigger, body: AutopilotIDBody(id: id), as: CITriggerResponse.self)
    }

    func watchedRepoPullRequests(id: String) async throws -> [CIPullRequest] {
        try await autopilotSend(.ciUpdates, .ciListPRs, body: AutopilotIDBody(id: id), as: CIPullRequestList.self).items
    }

    func closeWatchedRepoPR(id: String, prNumber: Int) async throws {
        try await autopilotSendVoid(.ciUpdates, .ciClosePR, body: AutopilotCIClosePRBody(id: id, prNumber: prNumber))
    }

    // MARK: - Docs

    func listDocsRepos(search: String? = nil, cursor: String? = nil) async throws -> DocsRepoListResponse {
        try await autopilotSend(.docs, .docsList, body: AutopilotReposQuery(search: search, cursor: cursor), as: DocsRepoListResponse.self)
    }

    func addDocsRepo(_ body: AddDocsRepoBody) async throws {
        try await autopilotSendVoid(.docs, .docsAdd, body: body)
    }

    func deleteDocsRepo(id: String) async throws {
        try await autopilotSendVoid(.docs, .docsDelete, body: AutopilotIDBody(id: id))
    }

    func listDocuments(repoId: String, cursor: String? = nil) async throws -> DocsDocumentList {
        try await autopilotSend(.docs, .docsListDocuments, body: AutopilotDocsListDocumentsBody(repoId: repoId, cursor: cursor), as: DocsDocumentList.self)
    }

    func getDocument(repoId: String, docId: String) async throws -> DocsDocumentDetail {
        try await autopilotSend(.docs, .docsGetDocument, body: AutopilotDocsDocBody(repoId: repoId, docId: docId), as: DocsDocumentDetail.self)
    }

    @discardableResult
    func uploadDocument(repoId: String, docId: String, content: String, originalLink: String?) async throws -> DocsUploadResult {
        try await autopilotSend(.docs, .docsUploadDocument,
                                body: AutopilotDocsUploadBody(repoId: repoId, docId: docId, content: content, originalLink: originalLink),
                                as: DocsUploadResult.self)
    }

    func deleteDocument(repoId: String, docId: String) async throws {
        try await autopilotSendVoid(.docs, .docsDeleteDocument, body: AutopilotDocsDocBody(repoId: repoId, docId: docId))
    }

    // MARK: - Global search

    /// One round trip that returns both on-device thread matches and published
    /// docs matches for `query`. The desktop owns both corpora, so this single
    /// request/response RPC replaces stitching two separate relay messages
    /// together.
    func searchThreadsAndDocs(query: String, limit: Int = 25) async throws -> AutopilotSearchResult {
        try await autopilotSend(.search, .searchThreadsAndDocs,
                                body: AutopilotSearchBody(query: query, limit: limit),
                                as: AutopilotSearchResult.self)
    }

    @discardableResult
    func createDocsUploadToken(repoId: String, name: String?) async throws -> DocsUploadToken {
        try await autopilotSend(.docs, .docsCreateUploadToken, body: AutopilotDocsCreateTokenBody(repoId: repoId, name: name), as: DocsUploadToken.self)
    }

    @discardableResult
    func installDocsGithubSecret(repoId: String) async throws -> DocsGithubSecretResult {
        try await autopilotSend(.docs, .docsInstallGithubSecret, body: AutopilotRepoIDBody(repoId: repoId), as: DocsGithubSecretResult.self)
    }

    // MARK: - Release

    func listReleaseRepos(cursor: String? = nil) async throws -> ReleaseRepoListResponse {
        try await autopilotSend(.release, .releaseList, body: AutopilotCursorQuery(cursor: cursor), as: ReleaseRepoListResponse.self)
    }

    func addReleaseRepo(_ body: AddReleaseRepoBody) async throws {
        try await autopilotSendVoid(.release, .releaseAdd, body: body)
    }

    func deleteReleaseRepo(id: String) async throws {
        try await autopilotSendVoid(.release, .releaseDelete, body: AutopilotIDBody(id: id))
    }

    func listReleaseWorkflows(repoId: String) async throws -> [MobileReleaseWorkflow] {
        try await autopilotSend(.release, .releaseListWorkflows, body: AutopilotRepoIDBody(repoId: repoId), as: MobileReleaseWorkflowList.self).items
    }

    @discardableResult
    func dispatchRelease(repoId: String, request: ReleaseDispatchRequest) async throws -> ReleaseDispatchResult {
        try await autopilotSend(.release, .releaseDispatch, body: AutopilotReleaseDispatchBody(repoId: repoId, request: request), as: ReleaseDispatchResult.self)
    }

    @discardableResult
    func installReleaseToken(repoId: String, value: String) async throws -> ReleaseGithubSecretResult {
        try await autopilotSend(.release, .releaseInstallToken, body: AutopilotReleaseTokenBody(repoId: repoId, value: value), as: ReleaseGithubSecretResult.self)
    }

    // MARK: - Project context-menu actions (desktop-mediated, 1:1 with macOS)

    /// Per-project autopilot state (has secrets / docs / release), mirroring the
    /// desktop checks that decide which context-menu items to show.
    func projectAutopilotStatus(projectId: UUID) async throws -> AutopilotProjectStatus {
        try await autopilotSend(.project, .projectAutopilotStatus,
                                body: AutopilotProjectBody(projectId: projectId),
                                as: AutopilotProjectStatus.self)
    }

    /// Asks the Mac to surface the secrets-setup flow for the project (same as
    /// the desktop "Set Up Secrets" menu item).
    func requestProjectSecretsSetup(projectId: UUID) async throws {
        try await autopilotSendVoid(.project, .projectSecretsSetup, body: AutopilotProjectBody(projectId: projectId))
    }

    /// Asks the Mac to start the docs-setup chat for the project ("Set Up Docs").
    func requestProjectDocsSetup(projectId: UUID) async throws {
        try await autopilotSendVoid(.project, .projectDocsSetup, body: AutopilotProjectBody(projectId: projectId))
    }

    /// Asks the Mac to open its docs search overlay ("Search Docs").
    func requestProjectDocsSearch(projectId: UUID) async throws {
        try await autopilotSendVoid(.project, .projectDocsSearch, body: AutopilotProjectBody(projectId: projectId))
    }

    /// Asks the Mac to start the release-setup chat for the project.
    func requestProjectReleaseSetup(projectId: UUID) async throws {
        try await autopilotSendVoid(.project, .projectReleaseSetup, body: AutopilotProjectBody(projectId: projectId))
    }

    /// Asks the Mac to present its create-release sheet for the project.
    func requestProjectReleaseCreate(projectId: UUID) async throws {
        try await autopilotSendVoid(.project, .projectReleaseCreate, body: AutopilotProjectBody(projectId: projectId))
    }

    /// Asks the Mac to open a pull request for the project's branch: it pushes
    /// the branch, generates the PR title/body from the branch briefing, and
    /// opens the PR (the Mac holds the GitHub token + checkout). Returns the PR
    /// URL so the phone can open it.
    func requestProjectCreatePullRequest(projectId: UUID, branch: String) async throws -> URL {
        let result = try await autopilotSend(.project, .projectCreatePullRequest,
                                             body: AutopilotProjectBranchBody(projectId: projectId, branch: branch),
                                             as: AutopilotPullRequestResult.self)
        guard let url = URL(string: result.url) else {
            throw AutopilotRemoteError.server(String(localized: "The Mac returned an invalid pull-request URL."))
        }
        return url
    }

    /// Asks the Mac to start a `[Code Review]` thread reviewing the whole branch
    /// (grounded in its briefing). Returns the new thread id so the phone can
    /// navigate to it once it syncs over.
    @discardableResult
    func requestProjectCreateCodeReview(projectId: UUID, branch: String) async throws -> String {
        try await autopilotSend(.project, .projectCreateCodeReview,
                                body: AutopilotProjectBranchBody(projectId: projectId, branch: branch),
                                as: AutopilotCodeReviewResult.self).threadId
    }

    /// Asks the Mac to start a `[Code Review]` thread reviewing a single thread's
    /// changes (the manual equivalent of the built-in Code Review hook). Returns
    /// the new review thread's id.
    @discardableResult
    func requestThreadCreateCodeReview(sessionId: String) async throws -> String {
        try await autopilotSend(.project, .threadCreateCodeReview,
                                body: AutopilotThreadBody(sessionId: sessionId),
                                as: AutopilotCodeReviewResult.self).threadId
    }

    /// Asks the Mac to start a commit-only thread for all current uncommitted
    /// project changes. Returns the thread id.
    @discardableResult
    func requestProjectCommitAll(projectId: UUID) async throws -> String {
        try await autopilotSend(.project, .projectCommitAll,
                                body: AutopilotProjectBody(projectId: projectId),
                                as: AutopilotCodeReviewResult.self).threadId
    }

    /// Asks the Mac to commit only the files recorded for one thread. Returns the
    /// updated thread id.
    @discardableResult
    func requestThreadCommitFiles(sessionId: String) async throws -> String {
        try await autopilotSend(.project, .threadCommitFiles,
                                body: AutopilotThreadBody(sessionId: sessionId),
                                as: AutopilotCodeReviewResult.self).threadId
    }

    /// Downloads the chosen environment into the project folder. The phone
    /// decrypts on-device with its passkey-derived KEK (the same iCloud-synced
    /// credential the Mac uses) — running the phone's own passkey ceremony — then
    /// sends the plaintext over the E2E-encrypted relay; the Mac only writes the
    /// files into the project folder, with no passkey prompt on the Mac. Returns
    /// the files written and any skipped conflicts.
    @discardableResult
    func downloadProjectSecrets(projectId: UUID, repo: String, envId: String, overwrite: Bool) async throws -> AutopilotProjectSecretsDownloadResult {
        let plaintext = try await secretEnvironmentPlaintext(repo: repo, envId: envId)
        let files = plaintext.map {
            AutopilotProjectSecretsWriteBody.Plaintext(filename: $0.filename, content: $0.content)
        }
        return try await autopilotSend(.project, .projectSecretsWrite,
                                       body: AutopilotProjectSecretsWriteBody(projectId: projectId, files: files, overwrite: overwrite),
                                       as: AutopilotProjectSecretsDownloadResult.self)
    }
}
