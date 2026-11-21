import Foundation
import RxCodeCore
import RxCodeSync

extension AppState {
    @MainActor
    func handleFlowcyTool(name: String, arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let allowedKeys: Set<String> = name == FlowcyTool.catalogName ? ["operation"]
            : name == "ide__get_ci_status" ? ["project_id", "page", "workflow_id", "run_id"]
            : ["operation", "parameters"]
        guard let input = arguments.objectValue, input.keys.allSatisfy(allowedKeys.contains) else {
            throw IDEToolError.invalidArguments("Unknown Flowcy tool argument. Inspect ide__flowcy_catalog for the supported contract.")
        }
        if name == FlowcyTool.catalogName {
            let requested = arguments["operation"]?.stringValue
            if let requested, FlowcyTool.operation(requested) == nil {
                throw IDEToolError.notSupported("Unknown Flowcy operation. Credential/key export and arbitrary API requests are unsupported.")
            }
            return jsonTextResult(.object([
                "operations": .array(FlowcyTool.operations.filter { requested == nil || $0.name == requested }.map {
                    .object(["operation": .string($0.name), "parameters": $0.schema,
                             "requires_confirmation": .bool($0.mutates), "note": .string($0.note)])
                }),
                "related_tools": .array(["ide__search_docs", "ide__get_ci_status", "ide__get_projects", "ide__get_tasks", "ide__create_task", "ide__update_task", "ide__delete_task", "ide__get_stories", "ide__create_story", "ide__link_story", "ide__task_views", "ide__send_notification", "ide__get_integration_usage"].map(JSONValue.string)),
                "boundaries": .string("Account permissions are enforced by Flowcy. Secret values, ciphertext bundles, encryption keys and token export are unavailable. Use secretsManage/secretsDownload/releaseTokenSetup for native user interaction. Task/story/view edits use existing IDE tools and cloud sync. CI logs are not exported because they may contain credentials. Catalog availability does not imply a deployed backend endpoint or a connected GitHub App.")
            ]))
        }
        guard isSignedIn || (name == FlowcyTool.name && arguments["operation"]?.stringValue == "accountStatus") else { return flowcyFailure("not_authenticated", "Sign in under Settings → Flowcy.") }
        do {
            if name == "ide__get_ci_status" {
                return jsonTextResult(try await liveFlowcyCI(arguments, sessionKey: sessionKey))
            }
            guard let raw = arguments["operation"]?.stringValue,
                  let operation = FlowcyTool.operation(raw) else {
                throw IDEToolError.invalidArguments("Select an operation from ide__flowcy_catalog.")
            }
            let parameters = arguments["parameters"] ?? .object([:])
            try FlowcyTool.validate(parameters, for: operation)
            // The allowlist is independent of the mobile dispatcher's broader trust boundary.
            // In particular, key/token/bundle and plaintext-write operations never reach it.
            if operation.mutates {
                let data = try JSONEncoder().encode(parameters)
                let summary = String(decoding: data, as: UTF8.self)
                let confirmed = await requestAgentConfirmation(.init(
                    title: "Flowcy: \(raw)", message: String(summary.prefix(12_000)),
                    confirmLabel: "Continue", isDestructive: raw.localizedCaseInsensitiveContains("delete") || raw == "trustedEmailRemove"
                ), sessionKey: sessionKey)
                guard confirmed else { return jsonTextResult(.object(["status": .string("cancelled"), "operation": .string(raw)])) }
            }
            try Task.checkCancellation()
            let result: JSONValue
            if operation.route == "mobile" {
                guard let op = AutopilotOp(rawValue: raw) else { throw IDEToolError.notSupported(raw) }
                let request = AutopilotRequestPayload(domain: .account, operation: op, body: try JSONEncoder().encode(parameters))
                let data = try await performAutopilotOperation(op, request: request)
                result = try data.map { try JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
            } else {
                result = try await performNativeFlowcy(raw, parameters: parameters, sessionKey: sessionKey)
            }
            let uiOperations: Set<String> = ["projectSecretsSetup", "projectDocsSetup", "projectDocsSearch", "projectReleaseSetup", "projectReleaseCreate", "secretsManage", "secretsDownload", "releaseTokenSetup"]
            if result["status"]?.stringValue == "sync_failed" {
                return flowcyFailure("sync_failed", "Cloud sync failed. The native project sync state contains the last successful sync time. No successful sync is claimed.")
            }
            return jsonTextResult(.object([
                "operation": .string(raw), "status": .string(uiOperations.contains(raw) ? "awaiting_user" : raw == "cloudLink" ? "sync_scheduled" : "completed"),
                "fetched_at": .string(Date().ISO8601Format()), "source": .string("native_flowcy_service"),
                "freshness": .string(raw == "projectAutopilotStatus" ? "cached_configuration; use service reads to verify" : raw == "repositories" ? "server repository cache may be up to 60 seconds old; pass refresh=true to refresh" : "service_response; inspect server indexing and update timestamps"),
                "result": result
            ]))
        } catch let error as IDEToolError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return safeFlowcyFailure(error)
        }
    }

    /// Live API only: do not use ciStatusByProject, which is webhook/poller state.
    @MainActor
    private func liveFlowcyCI(_ arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        if let value = arguments["project_id"], value.stringValue == nil {
            throw IDEToolError.invalidArguments("project_id must be a local project UUID string")
        }
        let projectId = try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        guard let repository = projects.first(where: { $0.id == projectId })?.gitHubRepo,
              repository.split(separator: "/").count == 2 else {
            return .object(["status": .string("missing_connection"), "message": .string("The selected project has no linked GitHub repository.")])
        }
        var parameters: [String: String] = [:]
        for (input, query) in [("page", "page"), ("workflow_id", "workflowId"), ("run_id", "runId")] {
            guard let value = arguments[input] else { continue }
            guard let number = value.numberValue, number.isFinite, number.rounded() == number,
                  number > 0, number <= 9_007_199_254_740_991 else {
                throw IDEToolError.invalidArguments("\(input) must be a positive safe integer")
            }
            parameters[query] = String(format: "%.0f", number)
        }
        guard arguments["workflow_id"] == nil || arguments["run_id"] == nil else {
            throw IDEToolError.invalidArguments("Use workflow_id for runs or run_id for jobs, not both.")
        }
        let response: JSONValue = try await autopilot.ciActivity(repository: repository, parameters: parameters)
        let collection = arguments["run_id"] == nil ? "runs" : "jobs"
        guard response[collection]?.arrayValue != nil else {
            return .object(["status": .string("unsupported_response"), "message": .string("Flowcy did not return the expected live CI collection. No cached status was substituted.")])
        }
        return .object([
            "status": .string("completed"), "project_id": .string(projectId.uuidString),
            "repository": .string(repository), "source": .string("github_actions_live_via_flowcy"),
            "fetched_at": .string(Date().ISO8601Format()), "stale": .bool(false),
            "scope": .string(arguments["run_id"] == nil ? "repository workflow runs, all branches, paginated" : "jobs for the selected run"),
            "result": Self.flowcyCIProjection(response)
        ])
    }

    /// Return only operational CI fields, never logs or arbitrary upstream payloads.
    nonisolated static func flowcyCIProjection(_ response: JSONValue) -> JSONValue {
        let runFields: Set<String> = ["id", "name", "display_title", "workflow_id", "run_number", "run_attempt", "event", "head_branch", "head_sha", "status", "conclusion", "html_url", "created_at", "updated_at", "run_started_at"]
        let jobFields: Set<String> = ["id", "run_id", "name", "status", "conclusion", "html_url", "started_at", "completed_at"]
        var result: [String: JSONValue] = [:]
        for (key, fields) in [("runs", runFields), ("jobs", jobFields)] {
            if let rows = response[key]?.arrayValue {
                result[key] = .array(rows.map { .object(($0.objectValue ?? [:]).filter { fields.contains($0.key) }) })
            }
        }
        if let more = response["hasMore"]?.boolValue { result["hasMore"] = .bool(more) }
        return .object(result)
    }

    @MainActor
    private func performNativeFlowcy(_ operation: String, parameters p: JSONValue, sessionKey: String) async throws -> JSONValue {
        func string(_ key: String) -> String { p[key]?.stringValue ?? "" }
        func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        }
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: JSONEncoder().encode(p))
        }
        switch operation {
        case "installations": return try encoded(await autopilot.listInstallations())
        case "installationPrecheck": return try encoded(await autopilot.precheckInstallations())
        case "repositories": return try encoded(await autopilot.listRepositories(search: p["search"]?.stringValue, cursor: p["cursor"]?.stringValue, refresh: p["refresh"]?.boolValue ?? false))
        case "repoSetupGet": return try encoded(await autopilot.getSetupTemplate(id: string("id")))
        case "docsVersions": return try encoded(await docs.listDocumentVersions(repoId: string("repoId"), docId: string("docId")))
        case "docsVersion": return try encoded(await docs.getDocumentVersion(repoId: string("repoId"), docId: string("docId"), version: Int(p["version"]!.numberValue!)))
        case "secretsSearchFiles": return try encoded(await secrets.searchFiles(repo: string("repo"), filenames: p["filenames"]!.arrayValue!.compactMap(\.stringValue)))
        case "secretsAddRepository": return try encoded(await secrets.addRepository(decode(AddSecretsRepoBody.self)))
        case "notificationUsage":
            let usage = try await autopilotNotifications.usage()
            return .object(["used": .number(Double(usage.used)), "limit": .number(Double(usage.limit)), "remaining": .number(Double(usage.remaining)), "resetsAt": try encoded(usage.resetsAt)])
        case "trustedEmails":
            let list = try await autopilotNotifications.listTrustedEmails()
            return .object(["accountEmail": try encoded(list.accountEmail), "items": try encoded(list.items)])
        case "trustedEmailAdd": return try encoded(await autopilotNotifications.addTrustedEmail(string("email")))
        case "trustedEmailRemove": try await autopilotNotifications.removeTrustedEmail(id: string("id")); return .null
        case "cloudDraft":
            guard let kind = ProjectCloudService.DraftKind(rawValue: string("kind")) else { throw IDEToolError.invalidArguments("kind must be task or story") }
            let draft = try await projectCloud.generateDraft(projectId: string("cloudId"), kind: kind, prompt: string("prompt"))
            return .object(["title": .string(draft.title), "details": .string(draft.details)])
        case "cloudDeviceRegister":
            try await projectCloud.registerDevice(id: cloudDeviceID, name: Host.current().localizedName ?? "Mac")
            return .object(["id": .string(cloudDeviceID)])
        case "cloudSavedViewsSave":
            let settings = try JSONDecoder().decode(CloudSavedViews.self, from: JSONEncoder().encode(p["settings"]!))
            return try encoded(await projectCloud.saveViews(settings, projectId: string("cloudId")))
        case "createPullRequest": return try encoded(await autopilot.createPullRequest(decode(CreatePullRequestRequest.self)))
        case "cloudStoryCreate", "cloudStoryUpdate":
            let fields = try JSONDecoder().decode(CloudStoryFields.self, from: JSONEncoder().encode(p["fields"]!))
            let row = operation == "cloudStoryCreate"
                ? try await projectCloud.createStory(projectId: string("cloudId"), fields: fields)
                : try await projectCloud.updateStory(projectId: string("cloudId"), storyId: string("id"), fields: fields)
            return .object(["id": .string(row.id), "fields": try encoded(row.fields)])
        case "cloudTaskCreate", "cloudTaskUpdate":
            let fields = try JSONDecoder().decode(CloudTaskFields.self, from: JSONEncoder().encode(p["fields"]!))
            let row = operation == "cloudTaskCreate"
                ? try await projectCloud.createTask(projectId: string("cloudId"), fields: fields)
                : try await projectCloud.updateTask(projectId: string("cloudId"), taskId: string("id"), fields: fields)
            return .object(["id": .string(row.id), "fields": try encoded(row.fields)])
        case "cloudStoryDelete": try await projectCloud.deleteStory(projectId: string("cloudId"), storyId: string("id")); return .null
        case "cloudTaskDelete": try await projectCloud.deleteTask(projectId: string("cloudId"), taskId: string("id")); return .null
        case "cloudProjects": return try encoded(await projectCloud.listProjects())
        case "cloudProjectCreate": return try encoded(await projectCloud.createProject(name: string("name"), description: p["description"]?.stringValue))
        case "cloudDevices": return try encoded(await projectCloud.listDevices())
        case "cloudBoard":
            let board = try await projectCloud.board(projectId: string("cloudId"))
            return .object([
                "members": try encoded(board.members), "role": try encoded(board.role),
                "currentUserId": try encoded(board.currentUserId),
                "stories": .array(try board.stories.map { row in
                    .object(["id": .string(row.id), "fields": try encoded(row.fields), "updatedAt": row.updatedAt.map { .string($0.ISO8601Format()) } ?? .null])
                }),
                "tasks": .array(try board.tasks.map { row in
                    .object(["id": .string(row.id), "fields": try encoded(row.fields), "updatedAt": row.updatedAt.map { .string($0.ISO8601Format()) } ?? .null])
                })
            ])
        case "cloudSavedViews": return try encoded(await projectCloud.savedViews(projectId: string("cloudId")))
        case "cloudLink", "cloudEnable", "cloudDisable", "cloudSync", "secretsManage", "secretsDownload", "releaseTokenSetup":
            let id = try taskToolProjectId(arguments: p, sessionKey: sessionKey)
            guard let project = projects.first(where: { $0.id == id }) else { throw IDEToolError.invalidArguments("Unknown project") }
            switch operation {
            case "cloudLink":
                let accessible = try await projectCloud.listProjects()
                guard accessible.contains(where: { $0.id == string("cloudId") }) else { throw IDEToolError.invalidArguments("Cloud project is not accessible to this account.") }
                await linkProject(id, toCloudProject: string("cloudId"))
            case "cloudEnable": try await enableCloudSync(for: id)
            case "cloudDisable": await disableCloudSync(for: id)
            case "cloudSync":
                guard project.cloudId != nil else { throw IDEToolError.invalidArguments("Project is not linked to Flowcy.") }
                await syncCloudBoard(projectId: id)
            case "secretsManage": secretsSetupRequest = SecretsSetupRequest(repoFullName: project.gitHubRepo, projectPath: project.path, filename: nil)
            case "secretsDownload": secretsDownloadRequest = project
            default: releaseSetupRequest = ReleaseSetupRequest(projectId: id, repoFullName: project.gitHubRepo)
            }
            if cloudSyncError(for: id) != nil, operation.hasPrefix("cloud") {
                return .object(["status": .string("sync_failed"), "message": .string("Cloud sync failed. Inspect the project's native sync error and retry."), "stale": .bool(true), "last_synced_at": cloudLastSyncedAt(for: id).map { .string($0.ISO8601Format()) } ?? .null])
            }
            return .object(["project_id": .string(id.uuidString), "sync_status": .string(operation == "cloudLink" ? "scheduled" : "inspect_native_state")])
        case "cloudChatModels", "cloudChat":
            let models = try await flowcyCloudBackend.fetchModels()
            if operation == "cloudChatModels" {
                return .array(models.map { .object(["id": .string($0.id), "alias": .string($0.displayName)]) })
            }
            guard let model = p["model"]?.stringValue ?? models.first?.id else {
                throw IDEToolError.notSupported("No Flowcy chat models are configured.")
            }
            guard models.contains(where: { $0.id == model }) else {
                throw IDEToolError.invalidArguments("Model is not in the current Flowcy catalog.")
            }
            let text = try await flowcyCloudBackend.reply(model: model, prompt: string("prompt"))
            return .object(["model": .string(model), "text": .string(text)])
        default: throw IDEToolError.notSupported("No native Flowcy handler for \(operation)")
        }
    }

    private func flowcyFailure(_ status: String, _ message: String) -> JSONValue {
        var result = jsonTextResult(.object(["status": .string(status), "message": .string(message), "stale": .bool(true)]))
        if case .object(var object) = result { object["isError"] = .bool(true); result = .object(object) }
        return result
    }

    /// Never echo raw HTTP bodies into the agent context: server errors may contain secrets.
    func safeFlowcyFailure(_ error: Error) -> JSONValue {
        let code: Int?
        switch error {
        case AutopilotService.ServiceError.notAuthenticated, DocsService.ServiceError.notAuthenticated,
             CIUpdateService.ServiceError.notAuthenticated, ReleaseService.ServiceError.notAuthenticated,
             SecretsService.ServiceError.notAuthenticated, AutopilotNotificationService.ServiceError.notAuthenticated:
            return flowcyFailure("not_authenticated", "Flowcy sign-in expired. Sign in again in Settings.")
        default: break
        }
        switch error {
        case AutopilotService.ServiceError.apiError(let status, _): code = status
        case DocsService.ServiceError.apiError(let status, _): code = status
        case CIUpdateService.ServiceError.apiError(let status, _): code = status
        case ReleaseService.ServiceError.apiError(let status, _): code = status
        case SecretsService.ServiceError.apiError(let status, _): code = status
        case AutopilotNotificationService.ServiceError.apiError(let status, _): code = status
        default: code = nil
        }
        switch code {
        case 401: return flowcyFailure("not_authenticated", "Flowcy sign-in expired. Sign in again in Settings.")
        case 403: return flowcyFailure("permission_denied", "Flowcy or the GitHub App denied access. Check the account and installation permissions.")
        case 404: return flowcyFailure("not_found_or_unsupported", "Repository or resource is inaccessible or missing, or the Flowcy endpoint is not deployed. Check the GitHub connection and backend version.")
        case 405, 501: return flowcyFailure("unsupported", "This operation is not supported by the connected Flowcy backend.")
        case 410: return flowcyFailure("expired", "The requested GitHub run or resource is no longer available.")
        case 429: return flowcyFailure("rate_limited", "Flowcy or GitHub rate limit reached. Retry later.")
        default: return flowcyFailure("service_error", "The native Flowcy request failed. No cached result was substituted. Check sign-in, network, and backend compatibility in the native UI.")
        }
    }
}
