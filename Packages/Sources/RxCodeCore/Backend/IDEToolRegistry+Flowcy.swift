import Foundation

/// Explicit allowlist for account-authenticated native Flowcy operations.
/// Never forward arbitrary paths, mobile op names, keys, tokens, or secret bundles.
public enum FlowcyTool {
    public static let name = "ide__flowcy"
    public static let catalogName = "ide__flowcy_catalog"

    public struct Operation: Sendable {
        public let name: String
        public let route: String
        public let mutates: Bool
        public let note: String
        public let properties: [String: JSONValue]
        public let required: [JSONValue]
        public var schema: JSONValue {
            .object(["type": .string("object"), "properties": .object(properties),
                     "required": .array(required), "additionalProperties": .bool(false)])
        }
    }

    public static let operations: [Operation] = [
        Operation(name: "accountStatus", route: "mobile", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "listManagedRepos", route: "mobile", mutates: false, note: "", properties: ["search": .object(["type": .string("string")]), "cursor": .object(["type": .string("string")])], required: []),
        Operation(name: "installGitHubAppUrl", route: "mobile", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "automationSchema", route: "mobile", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "automationValues", route: "mobile", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "repoSetupSchema", route: "mobile", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "repoSetupList", route: "mobile", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "secretsEnrollmentStatus", route: "mobile", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "ciList", route: "mobile", mutates: false, note: "", properties: ["cursor": .object(["type": .string("string")])], required: []),
        Operation(name: "docsList", route: "mobile", mutates: false, note: "", properties: ["search": .object(["type": .string("string")]), "cursor": .object(["type": .string("string")])], required: []),
        Operation(name: "releaseList", route: "mobile", mutates: false, note: "", properties: ["cursor": .object(["type": .string("string")])], required: []),
        Operation(name: "cloneManagedRepo", route: "mobile", mutates: true, note: "", properties: ["fullName": .object(["type": .string("string")])], required: [.string("fullName")]),
        Operation(name: "automationSave", route: "mobile", mutates: true, note: "Read automationSchema before editing values.", properties: ["values": .object(["type": .string("object")])], required: [.string("values")]),
        Operation(name: "repoSetupCreate", route: "mobile", mutates: true, note: "", properties: ["name": .object(["type": .string("string")]), "enabled": .object(["type": .string("boolean")]), "isDefault": .object(["type": .string("boolean")]), "mergeSettings": .object(["type": .string("object")]), "rulesetConfig": .object(["type": .string("object")])], required: [.string("name"), .string("enabled"), .string("isDefault"), .string("mergeSettings")]),
        Operation(name: "repoSetupUpdate", route: "mobile", mutates: true, note: "input is {name,enabled,isDefault,mergeSettings,rulesetConfig?}; read repoSetupSchema first.", properties: ["id": .object(["type": .string("string")]), "input": .object(["type": .string("object")])], required: [.string("id"), .string("input")]),
        Operation(name: "repoSetupDelete", route: "mobile", mutates: true, note: "", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "secretsListEnvironments", route: "mobile", mutates: false, note: "", properties: ["repo": .object(["type": .string("string")])], required: [.string("repo")]),
        Operation(name: "secretsListFiles", route: "mobile", mutates: false, note: "", properties: ["repo": .object(["type": .string("string")]), "envId": .object(["type": .string("string")])], required: [.string("repo"), .string("envId")]),
        Operation(name: "secretsDeleteEnvironment", route: "mobile", mutates: true, note: "", properties: ["repo": .object(["type": .string("string")]), "envId": .object(["type": .string("string")])], required: [.string("repo"), .string("envId")]),
        Operation(name: "secretsDeleteFile", route: "mobile", mutates: true, note: "", properties: ["repo": .object(["type": .string("string")]), "envId": .object(["type": .string("string")]), "fileId": .object(["type": .string("string")])], required: [.string("repo"), .string("envId"), .string("fileId")]),
        Operation(name: "ciOverview", route: "mobile", mutates: false, note: "id is the watched repository id; ciOverview uses owner/repo.", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "ciDelete", route: "mobile", mutates: true, note: "id is the watched repository id; ciOverview uses owner/repo.", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "ciTrigger", route: "mobile", mutates: true, note: "id is the watched repository id; ciOverview uses owner/repo.", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "ciTriggerDependencies", route: "mobile", mutates: true, note: "id is the watched repository id; ciOverview uses owner/repo.", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "ciListPRs", route: "mobile", mutates: false, note: "id is the watched repository id; ciOverview uses owner/repo.", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "ciAutomationGet", route: "mobile", mutates: false, note: "id is the watched repository id; ciOverview uses owner/repo.", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "ciAdd", route: "mobile", mutates: true, note: "Obtain installationId and repositoryId from listManagedRepos. repositoryFullName is owner/repo. scanFrequency, when required, is daily, weekly, or monthly.", properties: ["installationId": .object(["type": .string("integer")]), "repositoryId": .object(["type": .string("integer")]), "repositoryFullName": .object(["type": .string("string")]), "scanFrequency": .object(["type": .string("string")])], required: [.string("installationId"), .string("repositoryId"), .string("repositoryFullName"), .string("scanFrequency")]),
        Operation(name: "ciUpdateFrequency", route: "mobile", mutates: true, note: "frequency is daily, weekly, or monthly.", properties: ["id": .object(["type": .string("string")]), "frequency": .object(["type": .string("string")])], required: [.string("id"), .string("frequency")]),
        Operation(name: "ciHistory", route: "mobile", mutates: false, note: "", properties: ["id": .object(["type": .string("string")]), "limit": .object(["type": .string("integer")])], required: [.string("id")]),
        Operation(name: "ciClosePR", route: "mobile", mutates: true, note: "", properties: ["id": .object(["type": .string("string")]), "prNumber": .object(["type": .string("integer")])], required: [.string("id"), .string("prNumber")]),
        Operation(name: "ciAutomationSave", route: "mobile", mutates: true, note: "Read ciAutomationGet first and pass its complete settings object. Fields: dependenciesEnabled, dependencyCiRepair, dependencyAutoMerge, ciAutoMerge, dependencySecurityEnabled, ciSecurityEnabled, dependencyNotifications, ciNotifications (booleans), targets (array of {directory:string,manager:string}). Preserve fields you are not editing.", properties: ["id": .object(["type": .string("string")]), "settings": .object(["type": .string("object")])], required: [.string("id"), .string("settings")]),
        Operation(name: "ciDirectories", route: "mobile", mutates: false, note: "", properties: ["id": .object(["type": .string("string")]), "sha": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "docsAdd", route: "mobile", mutates: true, note: "Obtain installationId and repositoryId from listManagedRepos. repositoryFullName is owner/repo. scanFrequency, when required, is daily, weekly, or monthly.", properties: ["installationId": .object(["type": .string("integer")]), "repositoryId": .object(["type": .string("integer")]), "repositoryFullName": .object(["type": .string("string")])], required: [.string("installationId"), .string("repositoryId"), .string("repositoryFullName")]),
        Operation(name: "docsDelete", route: "mobile", mutates: true, note: "", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "releaseAdd", route: "mobile", mutates: true, note: "Obtain installationId and repositoryId from listManagedRepos. repositoryFullName is owner/repo. scanFrequency, when required, is daily, weekly, or monthly.", properties: ["installationId": .object(["type": .string("integer")]), "repositoryId": .object(["type": .string("integer")]), "repositoryFullName": .object(["type": .string("string")])], required: [.string("installationId"), .string("repositoryId"), .string("repositoryFullName")]),
        Operation(name: "releaseDelete", route: "mobile", mutates: true, note: "", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "docsListDocuments", route: "mobile", mutates: false, note: "", properties: ["repoId": .object(["type": .string("string")]), "cursor": .object(["type": .string("string")])], required: [.string("repoId")]),
        Operation(name: "docsGetDocument", route: "mobile", mutates: false, note: "Returns currentVersion.content as full Markdown, plus source/version/indexing metadata.", properties: ["repoId": .object(["type": .string("string")]), "docId": .object(["type": .string("string")])], required: [.string("repoId"), .string("docId")]),
        Operation(name: "docsUploadDocument", route: "mobile", mutates: true, note: "Indexing is asynchronous. Returns job/acceptance metadata, not completed indexing.", properties: ["repoId": .object(["type": .string("string")]), "docId": .object(["type": .string("string")]), "content": .object(["type": .string("string")]), "originalLink": .object(["type": .string("string")])], required: [.string("repoId"), .string("docId"), .string("content")]),
        Operation(name: "docsDeleteDocument", route: "mobile", mutates: true, note: "", properties: ["repoId": .object(["type": .string("string")]), "docId": .object(["type": .string("string")])], required: [.string("repoId"), .string("docId")]),
        Operation(name: "docsInstallGithubSecret", route: "mobile", mutates: true, note: "Installs token server-side. No credential value is returned.", properties: ["repoId": .object(["type": .string("string")])], required: [.string("repoId")]),
        Operation(name: "releaseBranches", route: "mobile", mutates: false, note: "", properties: ["repoId": .object(["type": .string("string")])], required: [.string("repoId")]),
        Operation(name: "releaseDispatchHistory", route: "mobile", mutates: false, note: "", properties: ["repoId": .object(["type": .string("string")])], required: [.string("repoId")]),
        Operation(name: "releaseListWorkflows", route: "mobile", mutates: false, note: "", properties: ["repoId": .object(["type": .string("string")])], required: [.string("repoId")]),
        Operation(name: "releaseRescanWorkflows", route: "mobile", mutates: true, note: "", properties: ["repoId": .object(["type": .string("string")])], required: [.string("repoId")]),
        Operation(name: "releaseSetWorkflowSelected", route: "mobile", mutates: true, note: "", properties: ["repoId": .object(["type": .string("string")]), "workflowId": .object(["type": .string("string")]), "isSelected": .object(["type": .string("boolean")])], required: [.string("repoId"), .string("workflowId"), .string("isSelected")]),
        Operation(name: "releaseDispatch", route: "mobile", mutates: true, note: "request is {workflowId:string,branch:string,inputs:object of string values}. Can publish a release.", properties: ["repoId": .object(["type": .string("string")]), "request": .object(["type": .string("object")])], required: [.string("repoId"), .string("request")]),
        Operation(name: "projectAutopilotStatus", route: "mobile", mutates: false, note: "Uses a local project UUID. Setup/create operations open the existing native flow; they do not claim completion.", properties: ["projectId": .object(["type": .string("string")])], required: [.string("projectId")]),
        Operation(name: "projectSecretsSetup", route: "mobile", mutates: true, note: "Uses a local project UUID. Setup/create operations open the existing native flow; they do not claim completion.", properties: ["projectId": .object(["type": .string("string")])], required: [.string("projectId")]),
        Operation(name: "projectDocsSetup", route: "mobile", mutates: true, note: "Uses a local project UUID. Setup/create operations open the existing native flow; they do not claim completion.", properties: ["projectId": .object(["type": .string("string")])], required: [.string("projectId")]),
        Operation(name: "projectDocsSearch", route: "mobile", mutates: true, note: "Uses a local project UUID. Setup/create operations open the existing native flow; they do not claim completion.", properties: ["projectId": .object(["type": .string("string")])], required: [.string("projectId")]),
        Operation(name: "projectReleaseSetup", route: "mobile", mutates: true, note: "Uses a local project UUID. Setup/create operations open the existing native flow; they do not claim completion.", properties: ["projectId": .object(["type": .string("string")])], required: [.string("projectId")]),
        Operation(name: "projectReleaseCreate", route: "mobile", mutates: true, note: "Uses a local project UUID. Setup/create operations open the existing native flow; they do not claim completion.", properties: ["projectId": .object(["type": .string("string")])], required: [.string("projectId")]),
        Operation(name: "installations", route: "native", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "installationPrecheck", route: "native", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "repositories", route: "native", mutates: false, note: "", properties: ["refresh": .object(["type": .string("boolean")]), "search": .object(["type": .string("string")]), "cursor": .object(["type": .string("string")])], required: []),
        Operation(name: "repoSetupGet", route: "native", mutates: false, note: "", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "docsVersions", route: "native", mutates: false, note: "", properties: ["repoId": .object(["type": .string("string")]), "docId": .object(["type": .string("string")])], required: [.string("repoId"), .string("docId")]),
        Operation(name: "docsVersion", route: "native", mutates: false, note: "", properties: ["repoId": .object(["type": .string("string")]), "docId": .object(["type": .string("string")]), "version": .object(["type": .string("integer")])], required: [.string("repoId"), .string("docId"), .string("version")]),
        Operation(name: "secretsSearchFiles", route: "native", mutates: false, note: "Metadata only; never returns secret contents.", properties: ["repo": .object(["type": .string("string")]), "filenames": .object(["type": .string("array"), "items": .object(["type": .string("string")])])], required: [.string("repo"), .string("filenames")]),
        Operation(name: "secretsAddRepository", route: "native", mutates: true, note: "Obtain installationId and repositoryId from listManagedRepos. repositoryFullName is owner/repo. scanFrequency, when required, is daily, weekly, or monthly.", properties: ["installationId": .object(["type": .string("integer")]), "repositoryId": .object(["type": .string("integer")]), "repositoryFullName": .object(["type": .string("string")])], required: [.string("installationId"), .string("repositoryId"), .string("repositoryFullName")]),
        Operation(name: "notificationUsage", route: "native", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "trustedEmails", route: "native", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "trustedEmailAdd", route: "native", mutates: true, note: "Sends a verification email; requires user confirmation.", properties: ["email": .object(["type": .string("string")])], required: [.string("email")]),
        Operation(name: "trustedEmailRemove", route: "native", mutates: true, note: "", properties: ["id": .object(["type": .string("string")])], required: [.string("id")]),
        Operation(name: "cloudProjects", route: "native", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "cloudProjectCreate", route: "native", mutates: true, note: "", properties: ["name": .object(["type": .string("string")]), "description": .object(["type": .string("string")])], required: [.string("name")]),
        Operation(name: "cloudDevices", route: "native", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "cloudBoard", route: "native", mutates: false, note: "Read-only server snapshot; use existing IDE task/story tools to edit a linked board.", properties: ["cloudId": .object(["type": .string("string")])], required: [.string("cloudId")]),
        Operation(name: "cloudSavedViews", route: "native", mutates: false, note: "Use ide__task_views to edit a linked board.", properties: ["cloudId": .object(["type": .string("string")])], required: [.string("cloudId")]),
        Operation(name: "cloudLink", route: "native", mutates: true, note: "Links an existing local project to an accessible cloud project.", properties: ["project_id": .object(["type": .string("string")]), "cloudId": .object(["type": .string("string")])], required: [.string("project_id"), .string("cloudId")]),
        Operation(name: "cloudEnable", route: "native", mutates: true, note: "", properties: ["project_id": .object(["type": .string("string")])], required: [.string("project_id")]),
        Operation(name: "cloudDisable", route: "native", mutates: true, note: "", properties: ["project_id": .object(["type": .string("string")])], required: [.string("project_id")]),
        Operation(name: "cloudSync", route: "native", mutates: true, note: "", properties: ["project_id": .object(["type": .string("string")])], required: [.string("project_id")]),
        Operation(name: "cloudChatModels", route: "native", mutates: false, note: "", properties: [:], required: []),
        Operation(name: "cloudChat", route: "native", mutates: true, note: "Uses a separate ephemeral native chat; bills the signed-in Flowcy account.", properties: ["prompt": .object(["type": .string("string")]), "model": .object(["type": .string("string")])], required: [.string("prompt")]),
        Operation(name: "secretsManage", route: "native", mutates: true, note: "Opens the native secrets setup flow; encryption/key enrollment remain in native UI.", properties: ["project_id": .object(["type": .string("string")])], required: [.string("project_id")]),
        Operation(name: "secretsDownload", route: "native", mutates: true, note: "Opens the native environment selection/unlock flow; no file contents enter MCP.", properties: ["project_id": .object(["type": .string("string")])], required: [.string("project_id")]),
        Operation(name: "releaseTokenSetup", route: "native", mutates: true, note: "Opens native release setup. Enter credentials only in that UI.", properties: ["project_id": .object(["type": .string("string")])], required: [.string("project_id")]),
        Operation(name: "cloudDraft", route: "native", mutates: true, note: "Generate a task/story draft using the account cloud model.", properties: ["cloudId": .object(["type": .string("string")]), "kind": .object(["type": .string("string")]), "prompt": .object(["type": .string("string")])], required: [.string("cloudId"), .string("kind"), .string("prompt")]),
        Operation(name: "cloudDeviceRegister", route: "native", mutates: true, note: "Register this Mac using its existing device identity.", properties: [:], required: []),
        Operation(name: "cloudSavedViewsSave", route: "native", mutates: true, note: "settings is CloudSavedViews; read cloudSavedViews first and preserve revision.", properties: ["cloudId": .object(["type": .string("string")]), "settings": .object(["type": .string("object")])], required: [.string("cloudId"), .string("settings")]),
        Operation(name: "createPullRequest", route: "native", mutates: true, note: "Creates a PR through the signed-in GitHub App; does not push local commits.", properties: ["owner": .object(["type": .string("string")]), "repo": .object(["type": .string("string")]), "head": .object(["type": .string("string")]), "base": .object(["type": .string("string")]), "title": .object(["type": .string("string")]), "body": .object(["type": .string("string")])], required: [.string("owner"), .string("repo"), .string("head"), .string("title")]),
        Operation(name: "cloudStoryCreate", route: "native", mutates: true, note: "Uses cloud IDs, not local UUIDs. fields follows the cloud board response. Refresh a linked board after editing.", properties: ["cloudId": .object(["type": .string("string")]), "fields": .object(["type": .string("object")])], required: [.string("cloudId"), .string("fields")]),
        Operation(name: "cloudStoryUpdate", route: "native", mutates: true, note: "Uses cloud IDs, not local UUIDs. fields follows the cloud board response. Refresh a linked board after editing.", properties: ["cloudId": .object(["type": .string("string")]), "id": .object(["type": .string("string")]), "fields": .object(["type": .string("object")])], required: [.string("cloudId"), .string("id"), .string("fields")]),
        Operation(name: "cloudStoryDelete", route: "native", mutates: true, note: "Uses cloud IDs, not local UUIDs. fields follows the cloud board response. Refresh a linked board after editing.", properties: ["cloudId": .object(["type": .string("string")]), "id": .object(["type": .string("string")])], required: [.string("cloudId"), .string("id")]),
        Operation(name: "cloudTaskCreate", route: "native", mutates: true, note: "Uses cloud IDs, not local UUIDs. fields follows the cloud board response. Refresh a linked board after editing.", properties: ["cloudId": .object(["type": .string("string")]), "fields": .object(["type": .string("object")])], required: [.string("cloudId"), .string("fields")]),
        Operation(name: "cloudTaskUpdate", route: "native", mutates: true, note: "Uses cloud IDs, not local UUIDs. fields follows the cloud board response. Refresh a linked board after editing.", properties: ["cloudId": .object(["type": .string("string")]), "id": .object(["type": .string("string")]), "fields": .object(["type": .string("object")])], required: [.string("cloudId"), .string("id"), .string("fields")]),
        Operation(name: "cloudTaskDelete", route: "native", mutates: true, note: "Uses cloud IDs, not local UUIDs. fields follows the cloud board response. Refresh a linked board after editing.", properties: ["cloudId": .object(["type": .string("string")]), "id": .object(["type": .string("string")])], required: [.string("cloudId"), .string("id")]),
    ]

    public static func operation(_ name: String) -> Operation? {
        operations.first { $0.name == name }
    }

    /// Validation also applies to direct dispatch, independently of MCP schema validation.
    public static func validate(_ parameters: JSONValue, for operation: Operation) throws {
        guard let object = parameters.objectValue else {
            throw IDEToolError.invalidArguments("parameters must be an object")
        }
        for key in object.keys where operation.properties[key] == nil {
            throw IDEToolError.invalidArguments("Unknown parameter '\(key)' for \(operation.name)")
        }
        for key in operation.required.compactMap(\.stringValue) where object[key] == nil {
            throw IDEToolError.invalidArguments("Missing parameter '\(key)' for \(operation.name)")
        }
        for (key, value) in object {
            let type = operation.properties[key]?["type"]?.stringValue
            let valid: Bool
            switch (type, value) {
            case ("string", .string(let text)): valid = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case ("integer", .number(let number)): valid = number.isFinite && number.rounded() == number && number > 0 && number <= 9_007_199_254_740_991
            case ("boolean", .bool): valid = true
            case ("object", .object): valid = true
            case ("array", .array(let entries)): valid = entries.allSatisfy { $0.stringValue != nil }
            default: valid = false
            }
            guard valid else { throw IDEToolError.invalidArguments("Invalid '\(key)' (expected \(type ?? "value"))") }
        }
    }
}

extension IDEToolRegistry {
    static let flowcyTools: [IDETool] = [
        IDETool(name: FlowcyTool.catalogName,
                description: "Inventory all native Flowcy MCP operations, their parameter schemas, side effects, and native UI boundaries. Call before ide__flowcy; optionally select one operation for its full contract. Existing task/story/view, docs search, notification, and usage tools remain available. Credential export is unsupported; use native secrets/release setup flows.",
                visibility: .alwaysIDEOnly,
                inputSchema: .object(["type": .string("object"), "properties": .object([
                    "operation": .object(["type": .string("string")])
                ]), "additionalProperties": .bool(false)])),
        IDETool(name: FlowcyTool.name,
                description: "Run an explicitly allowed native Flowcy operation with the signed-in account. First call ide__flowcy_catalog for its parameter contract. Mutations require native confirmation. Secret/key/token values are never accepted or returned. UI operations report awaiting_user, not completion. No arbitrary HTTP or mobile operation forwarding.",
                visibility: .alwaysIDEOnly,
                inputSchema: .object(["type": .string("object"), "properties": .object([
                    "operation": .object(["type": .string("string"), "enum": .array(FlowcyTool.operations.map { .string($0.name) })]),
                    "parameters": .object(["type": .string("object"), "description": .string("Parameters matching this operation's catalog schema; omit for parameterless operations.")])
                ]), "required": .array([.string("operation")]), "additionalProperties": .bool(false)])),
        IDETool(name: "ide__get_ci_status",
                description: "Fetch live GitHub Actions workflow runs for the selected project's linked repository through Flowcy. Returns actual queued/in_progress/completed states, conclusions, detail URLs and pagination, not billing metrics. Use run_id for job progress. Never substitutes the webhook cache for live results. Requires the signed-in account and an accessible GitHub App installation.",
                visibility: .alwaysIDEOnly,
                inputSchema: .object(["type": .string("object"), "properties": .object([
                    "project_id": .object(["type": .string("string")]),
                    "page": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "workflow_id": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "run_id": .object(["type": .string("integer"), "minimum": .number(1)])
                ]), "additionalProperties": .bool(false)]))
    ]
}
