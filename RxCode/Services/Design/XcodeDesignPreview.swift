import Foundation
import RxCodeCore

enum XcodeDesignPreview {
    nonisolated static func render(file: URL, project: URL, index: Int, workspaceID: String = "") async throws -> Data {
        let connection = MCPAppConnection(detail: .init(name: "Xcode", scope: .project, transport: .stdio, url: nil,
            command: "/usr/bin/xcrun", args: ["mcpbridge"], env: [:], projectPath: project.path), timeoutSeconds: 150)
        let schema: [JSONValue]
        do { schema = try await connection.nativeToolDescriptors() }
        catch { throw IDEToolError.handlerFailed("Open the project in Xcode and allow external agents in Xcode Settings → Intelligence. \(error.localizedDescription)") }
        guard let renderer = schema.first(where: { $0["name"]?.stringValue == "RenderPreview" }),
              let properties = renderer["inputSchema"]?["properties"]?.objectValue else {
            throw IDEToolError.handlerFailed("Xcode did not advertise RenderPreview. Check external agent access in Xcode Settings → Intelligence.")
        }
        let root = project.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard file.pathExtension.lowercased() == "swift", path.hasPrefix(root + "/"), index >= 0 else {
            throw IDEToolError.invalidArguments("Choose a Swift source file in the selected project and a nonnegative preview index.")
        }
        let workspace = workspaceFile(for: file, in: project)
        var args: [String: JSONValue] = [:]
        if let workspaceKey = ["tabIdentifier", "workspaceIdentifier"].first(where: { properties[$0] != nil }) {
            if !workspaceID.isEmpty { args[workspaceKey] = .string(workspaceID) }
            else if workspaceKey == "workspaceIdentifier",
                    schema.contains(where: { $0["name"]?.stringValue == "XcodeOpenWorkspace" }),
                    let workspace {
                let opened = try await connection.callNativeTool("XcodeOpenWorkspace", arguments: ["path": .string(workspace.path)])
                if opened["isError"]?.boolValue == true { throw IDEToolError.handlerFailed(textBlocks(opened).joined(separator: "\n")) }
                guard let id = matchingWorkspace(in: opened, root: workspace.path) else {
                    throw IDEToolError.handlerFailed("Xcode opened the project without returning its workspace identifier.")
                }
                args[workspaceKey] = .string(id)
            }
            else {
                let listTool = schema.contains { $0["name"]?.stringValue == "XcodeListWorkspaces" } ? "XcodeListWorkspaces" : "XcodeListWindows"
                let listing = try await connection.callNativeTool(listTool, arguments: [:])
                if listing["isError"]?.boolValue == true { throw IDEToolError.handlerFailed(textBlocks(listing).joined(separator: "\n")) }
                guard let id = matchingWorkspace(in: listing, root: root) else {
                    throw IDEToolError.handlerFailed("Open this project in Xcode or enter its workspace tab identifier in the preview sheet.")
                }
                args[workspaceKey] = .string(id)
            }
        }
        guard let pathKey = ["sourceFilePath", "filePath", "path"].first(where: { properties[$0] != nil }) else {
            throw IDEToolError.handlerFailed("This version of RenderPreview does not advertise a source path.")
        }
        let sourceRoot = workspace?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path ?? root
        guard path.hasPrefix(sourceRoot + "/") else {
            throw IDEToolError.invalidArguments("The Swift source is outside the selected Xcode workspace.")
        }
        args[pathKey] = .string(String(path.dropFirst(sourceRoot.count + 1)))
        if properties["previewDefinitionIndexInFile"] != nil { args["previewDefinitionIndexInFile"] = .number(Double(index)) }
        let output = try await connection.callNativeTool("RenderPreview", arguments: args)
        if output["isError"]?.boolValue == true { throw IDEToolError.handlerFailed(textBlocks(output).joined(separator: "\n")) }
        if let data = try snapshot(in: output) { return data }
        throw IDEToolError.handlerFailed(textBlocks(output).first ?? "Xcode returned no preview screenshot.")
    }

    nonisolated static func workspaceFile(for source: URL, in root: URL) -> URL? {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var folder = source.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        while folder.path == root.path || folder.path.hasPrefix(root.path + "/") {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for ext in ["xcworkspace", "xcodeproj"] {
                let candidates = items.filter { $0.pathExtension == ext }
                if candidates.count == 1 { return candidates[0] }
                if candidates.count > 1 { return nil }
            }
            if folder.path == root.path { break }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated static func matchingWorkspace(in result: JSONValue, root: String) -> String? {
        let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        var matches = Set<String>()
        func walk(_ value: JSONValue) {
            if let object = value.objectValue {
                if let path = object["workspacePath"]?.stringValue,
                   let id = (object["tabIdentifier"] ?? object["workspaceIdentifier"])?.stringValue {
                    let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                    if canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") { matches.insert(id) }
                }
                object.values.forEach(walk)
            } else if let list = value.arrayValue { list.forEach(walk) }
            else if let text = value.stringValue {
                if let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), decoded.objectValue != nil || decoded.arrayValue != nil { walk(decoded) }
                for line in text.components(separatedBy: .newlines) where line.contains(root + "/") {
                    if let range = line.range(of: #"(?:tabIdentifier|workspaceIdentifier)\s*[:=]\s*[\w.-]+"#, options: .regularExpression),
                       let id = line[range].split(whereSeparator: { ":=".contains($0) }).last {
                        matches.insert(id.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        walk(result)
        return matches.count == 1 ? matches.first : nil
    }

    nonisolated private static func textBlocks(_ result: JSONValue) -> [String] {
        result["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
    }

    nonisolated static func snapshot(in output: JSONValue) throws -> Data? {
        if let image = output["content"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "image" }),
           let base64 = image["data"]?.stringValue { return Data(base64Encoded: base64) }
        func file(_ value: JSONValue) -> URL? {
            if let object = value.objectValue {
                for key in ["previewSnapshotPath", "snapshotPath", "imagePath", "filePath", "path"] {
                    if let path = object[key]?.stringValue, path.hasPrefix("/") {
                        let url = URL(fileURLWithPath: path)
                        if ["png", "jpeg", "jpg", "heic"].contains(url.pathExtension.lowercased()) { return url }
                    }
                }
                return object.values.compactMap(file).first
            }
            return value.arrayValue?.compactMap(file).first
        }
        let values = [output] + textBlocks(output).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        if let url = values.compactMap(file).first { return try Data(contentsOf: url) }
        return nil
    }
}
