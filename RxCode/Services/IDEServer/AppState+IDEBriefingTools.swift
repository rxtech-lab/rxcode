import Foundation
import RxCodeCore

// MARK: - Briefing IDE tools
//
// Lets agents write document briefings stored by `BriefingStore`: create a
// draft, edit its content, add/replace/remove image, video, and file assets,
// then publish it so it appears on the briefing timeline.

extension AppState {
    @MainActor
    func handleBriefingToolCall(name: String, arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        do {
            let result: JSONValue
            switch name {
            case "ide__briefing_list":
                return try await handleBriefingList(arguments: arguments)
            case "ide__briefing_get":
                return try await handleBriefingGet(arguments: arguments)
            case "ide__briefing_create":
                result = try await handleBriefingCreate(arguments: arguments, sessionKey: sessionKey)
            case "ide__briefing_update":
                result = try await handleBriefingUpdate(arguments: arguments)
            case "ide__briefing_delete":
                result = try await handleBriefingDelete(arguments: arguments)
            case "ide__briefing_add_file":
                result = try await handleBriefingAddFile(arguments: arguments)
            case "ide__briefing_delete_file":
                result = try await handleBriefingDeleteFile(arguments: arguments)
            case "ide__briefing_publish":
                result = try await handleBriefingPublish(arguments: arguments, sessionKey: sessionKey)
            default:
                throw IDEToolError.unknownTool(name)
            }
            await reloadBriefingDocuments()
            return result
        } catch let error as BriefingStoreError {
            throw IDEToolError.invalidArguments(error.localizedDescription)
        }
    }

    // MARK: - Handlers

    private func handleBriefingList(arguments: JSONValue) async throws -> JSONValue {
        let projectId = try parseOptionalProjectId(arguments["project_id"]?.stringValue)
        let includeDrafts = arguments["include_drafts"]?.boolValue ?? true
        let briefings = await briefingStore.list().filter { briefing in
            (includeDrafts || briefing.isPublished)
                && (projectId == nil || briefing.projectId == projectId)
        }
        return jsonTextResult(.array(briefings.map { .object(briefingJSON($0)) }))
    }

    private func handleBriefingGet(arguments: JSONValue) async throws -> JSONValue {
        let id = try briefingId(arguments)
        let briefing = try await briefingStore.load(id)
        var result = briefingJSON(briefing)
        result["content"] = .string(try await briefingStore.content(of: id))
        result["files"] = .array(try await briefingStore.assets(of: id).map { .object(assetJSON($0, in: id)) })
        return jsonTextResult(.object(result))
    }

    private func handleBriefingCreate(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let title = trimmedString(arguments["title"])
        guard !title.isEmpty else { throw IDEToolError.invalidArguments("A nonempty 'title' is required.") }
        let format = try parseFormat(arguments["format"]) ?? .markdown
        let projectId = try briefingProjectId(arguments: arguments, sessionKey: sessionKey)
        let publish = arguments["publish"]?.boolValue ?? false
        let briefing = try await briefingStore.create(
            title: title,
            content: arguments["content"]?.stringValue ?? "",
            format: format,
            projectId: projectId,
            isDraft: !publish
        )
        if briefing.isPublished {
            briefingWasPublished(briefing, sessionKey: sessionKey)
        }
        var result = briefingJSON(briefing)
        result["folder_path"] = .string(briefingStore.folderURL(for: briefing.id).path)
        return jsonTextResult(.object(result))
    }

    private func handleBriefingUpdate(arguments: JSONValue) async throws -> JSONValue {
        let id = try briefingId(arguments)
        var briefing = try await briefingStore.load(id)
        let format = try parseFormat(arguments["format"])
        if let title = arguments["title"]?.stringValue {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw IDEToolError.invalidArguments("'title' cannot be empty.") }
            briefing = try await briefingStore.updateTitle(of: id, to: trimmed)
        }
        if let content = arguments["content"]?.stringValue {
            briefing = try await briefingStore.updateContent(of: id, content: content, format: format)
        } else if let format, format != briefing.format {
            // Switching format without new content keeps the existing body.
            let existing = try await briefingStore.content(of: id)
            briefing = try await briefingStore.updateContent(of: id, content: existing, format: format)
        }
        return jsonTextResult(.object(briefingJSON(briefing)))
    }

    private func handleBriefingDelete(arguments: JSONValue) async throws -> JSONValue {
        let id = try briefingId(arguments)
        try await briefingStore.delete(id)
        return textResult("Deleted briefing \(id.uuidString).")
    }

    private func handleBriefingAddFile(arguments: JSONValue) async throws -> JSONValue {
        let id = try briefingId(arguments)
        let kind = try parseAssetKind(arguments["kind"])
        let overwrite = arguments["overwrite"]?.boolValue ?? false
        let sourcePath = trimmedString(arguments["source_path"])
        let text = arguments["text"]?.stringValue
        let base64 = arguments["base64"]?.stringValue
        let sourceCount = [!sourcePath.isEmpty, text != nil, base64 != nil].filter { $0 }.count
        guard sourceCount == 1 else {
            throw IDEToolError.invalidArguments("Pass exactly one of 'source_path', 'text', or 'base64'.")
        }
        let requestedName = trimmedString(arguments["file_name"])

        let asset: BriefingAsset
        if !sourcePath.isEmpty {
            let url = URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard url.path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                throw IDEToolError.invalidArguments("'source_path' must be an absolute path to an existing file: \(sourcePath)")
            }
            asset = try await briefingStore.addAsset(
                to: id,
                copying: url,
                fileName: requestedName.isEmpty ? nil : requestedName,
                kind: kind,
                overwrite: overwrite
            )
        } else {
            guard !requestedName.isEmpty else {
                throw IDEToolError.invalidArguments("'file_name' is required with 'text' or 'base64'.")
            }
            let data: Data
            if let text {
                data = Data(text.utf8)
            } else if let decoded = Data(base64Encoded: base64 ?? "", options: .ignoreUnknownCharacters) {
                data = decoded
            } else {
                throw IDEToolError.invalidArguments("'base64' is not valid base64 data.")
            }
            asset = try await briefingStore.addAsset(
                to: id, fileName: requestedName, data: data, kind: kind, overwrite: overwrite
            )
        }
        return jsonTextResult(.object(assetJSON(asset, in: id)))
    }

    private func handleBriefingDeleteFile(arguments: JSONValue) async throws -> JSONValue {
        let id = try briefingId(arguments)
        let path = trimmedString(arguments["path"])
        guard let asset = BriefingAsset(relativePath: path) else {
            throw IDEToolError.invalidArguments(
                "'path' must be a briefing file path like 'images/chart.png', 'videos/demo.mp4', or 'files/data.csv'."
            )
        }
        try await briefingStore.removeAsset(asset, from: id)
        return textResult("Deleted \(asset.relativePath) from briefing \(id.uuidString).")
    }

    private func handleBriefingPublish(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let id = try briefingId(arguments)
        let briefing = arguments["unpublish"]?.boolValue == true
            ? try await briefingStore.unpublish(id)
            : try await briefingStore.publish(id)
        if briefing.isPublished {
            briefingWasPublished(briefing, sessionKey: sessionKey)
        }
        return jsonTextResult(.object(briefingJSON(briefing)))
    }

    // MARK: - Helpers

    private func briefingId(_ arguments: JSONValue) throws -> UUID {
        let raw = trimmedString(arguments["id"])
        guard let id = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("'id' must be a briefing UUID. Call ide__briefing_list to find one.")
        }
        return id
    }

    /// An explicit `project_id` must exist; otherwise the current chat's
    /// project is used, and a chat outside any project creates an unscoped
    /// briefing.
    private func briefingProjectId(arguments: JSONValue, sessionKey: String) throws -> UUID? {
        if let explicit = try parseOptionalProjectId(arguments["project_id"]?.stringValue) {
            guard projects.contains(where: { $0.id == explicit }) else {
                throw IDEToolError.invalidArguments("No project with id \(explicit.uuidString). Call ide__get_projects first.")
            }
            return explicit
        }
        let current = threadStore.fetch(id: sessionKey)?.projectId
            ?? allSessionSummaries.first(where: { $0.id == resolveCurrentSessionId(sessionKey) })?.projectId
        return current.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil }
    }

    private func parseFormat(_ value: JSONValue?) throws -> BriefingContentFormat? {
        let raw = trimmedString(value).lowercased()
        guard !raw.isEmpty else { return nil }
        guard let format = BriefingContentFormat(rawValue: raw) else {
            throw IDEToolError.invalidArguments("'format' must be 'markdown' or 'html'.")
        }
        return format
    }

    private func parseAssetKind(_ value: JSONValue?) throws -> BriefingAssetKind? {
        let raw = trimmedString(value).lowercased()
        guard !raw.isEmpty else { return nil }
        guard let kind = BriefingAssetKind(rawValue: raw) else {
            throw IDEToolError.invalidArguments("'kind' must be 'image', 'video', or 'file'.")
        }
        return kind
    }

    private func trimmedString(_ value: JSONValue?) -> String {
        value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func briefingJSON(_ briefing: BriefingDocument) -> [String: JSONValue] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": .string(briefing.id.uuidString),
            "title": .string(briefing.title),
            "format": .string(briefing.format.rawValue),
            "project_id": briefing.projectId.map { .string($0.uuidString) } ?? .null,
            "status": .string(briefing.isDraft ? "draft" : "published"),
            "created_at": .string(formatter.string(from: briefing.createdAt)),
            "updated_at": .string(formatter.string(from: briefing.updatedAt)),
            "published_at": briefing.publishedAt.map { .string(formatter.string(from: $0)) } ?? .null,
        ]
    }

    private func assetJSON(_ asset: BriefingAsset, in id: UUID) -> [String: JSONValue] {
        [
            "path": .string(asset.relativePath),
            "kind": .string(asset.kind.rawValue),
            "file_name": .string(asset.fileName),
            "byte_count": .number(Double(asset.byteCount)),
            "absolute_path": .string(briefingStore.assetURL(asset, in: id).path),
        ]
    }
}
