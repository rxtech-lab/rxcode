import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    func mobileFolderTreeRoot(for request: FolderTreeRequestPayload) throws -> RemoteFolderNode {
        let depth = max(0, min(request.depth, 2))
        guard let path = request.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return RemoteFolderNode(
                name: Host.current().localizedName ?? "Mac",
                path: "",
                isSelectable: false,
                children: mobileFolderPickerRoots(
                    depth: 1,
                    includeHidden: request.includeHidden,
                    includeFiles: request.includeFiles
                )
            )
        }

        return try mobileFolderNode(
            for: URL(fileURLWithPath: path).standardizedFileURL,
            depth: depth,
            includeHidden: request.includeHidden,
            includeFiles: request.includeFiles
        )
    }

    func mobileFolderPickerRoots(
        depth: Int,
        includeHidden: Bool,
        includeFiles: Bool
    ) -> [RemoteFolderNode] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var candidates = [
            home,
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Developer", isDirectory: true)
        ]

        let projectParents = projects
            .map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL }
        candidates.append(contentsOf: projectParents)

        var seen: Set<String> = []
        return candidates.compactMap { url in
            let path = url.path
            guard seen.insert(path).inserted else { return nil }
            return try? mobileFolderNode(
                for: url,
                depth: depth,
                includeHidden: includeHidden,
                includeFiles: includeFiles
            )
        }
    }

    func mobileFolderNode(
        for url: URL,
        depth: Int,
        includeHidden: Bool,
        includeFiles: Bool
    ) throws -> RemoteFolderNode {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MobileFolderPickerError.notFolder
        }

        let name = url == fm.homeDirectoryForCurrentUser.standardizedFileURL
            ? "Home"
            : url.lastPathComponent
        guard depth > 0 else {
            return RemoteFolderNode(name: name, path: url.path, children: [])
        }

        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: options
        )) ?? []

        // Keep directories (always) and plain files (when requested). Folders
        // sort first so navigation targets stay grouped above file leaves.
        let entries = contents
            .compactMap { child -> (url: URL, isDirectory: Bool)? in
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                else { return nil }
                if !includeHidden && (values.isHidden == true || child.lastPathComponent.hasPrefix(".")) {
                    return nil
                }
                if Self.mobileFolderIgnoredNames.contains(child.lastPathComponent) { return nil }
                let isDir = values.isDirectory == true
                if !isDir && !includeFiles { return nil }
                return (child, isDir)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            .prefix(Self.mobileFolderMaxChildren)

        let children = entries.compactMap { entry -> RemoteFolderNode? in
            if entry.isDirectory {
                return try? mobileFolderNode(
                    for: entry.url.standardizedFileURL,
                    depth: depth - 1,
                    includeHidden: includeHidden,
                    includeFiles: includeFiles
                )
            }
            return RemoteFolderNode(
                name: entry.url.lastPathComponent,
                path: entry.url.standardizedFileURL.path,
                isSelectable: false,
                isDirectory: false,
                children: []
            )
        }

        return RemoteFolderNode(name: name, path: url.path, children: Array(children))
    }

    func mobileFolderErrorMessage(_ error: Error) -> String {
        if let folderError = error as? MobileFolderPickerError {
            return folderError.localizedDescription
        }
        return error.localizedDescription
    }

    static let mobileFolderMaxChildren = 250
    static let mobileFolderIgnoredNames: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData",
        "node_modules", ".DS_Store", "Pods", "xcuserdata"
    ]

    enum MobileFolderPickerError: LocalizedError {
        case notFolder

        var errorDescription: String? {
            switch self {
            case .notFolder:
                return "Folder does not exist on the desktop."
            }
        }
    }
}
