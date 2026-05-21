import SwiftUI
import RxCodeCore

#if os(macOS)

// MARK: - @ File Search Popup

struct AtFilePopup: View {
    let entries: [AtFileEntry]
    let onSelect: (String) -> Void
    @Binding var selectedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text("File Search", bundle: .module)
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Spacer()
                Text("\(entries.count)")
                    .font(.system(size: ClaudeTheme.size(10)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()
                .foregroundStyle(ClaudeTheme.borderSubtle)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            fileRowButton(entry, isSelected: index == selectedIndex)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 320)
        .background(ClaudeTheme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium)
                .strokeBorder(ClaudeTheme.border, lineWidth: 1)
        )
        .shadow(color: ClaudeTheme.shadowColor, radius: 12, y: -4)
    }

    @ViewBuilder
    private func fileRowButton(_ entry: AtFileEntry, isSelected: Bool) -> some View {
        Button {
            onSelect(entry.relativePath)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(isSelected ? ClaudeTheme.accent : entry.iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textPrimary)

                    if !entry.directory.isEmpty {
                        Text(entry.directory)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? ClaudeTheme.accentSubtle : Color.clear)
    }

}

// MARK: - AtFileEntry

struct AtFileEntry: Identifiable {
    let id: String          // relativePath
    let name: String        // file name
    let directory: String   // parent directory path
    let relativePath: String

    var icon: String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx": return "chevron.left.forwardslash.chevron.right"
        case "json": return "curlybraces"
        case "md", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "svg", "pdf": return "photo"
        case "css", "scss": return "paintbrush"
        case "html": return "globe"
        case "yaml", "yml", "toml": return "gearshape"
        default: return "doc"
        }
    }

    var iconColor: Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "js", "jsx": return .yellow
        case "ts", "tsx": return .blue
        case "json": return ClaudeTheme.statusSuccess
        case "css", "scss": return .pink
        case "html": return ClaudeTheme.statusError
        case "png", "jpg", "jpeg", "svg", "pdf": return .purple
        default: return ClaudeTheme.textTertiary
        }
    }
}

// MARK: - AtFileSearch

enum AtFileSearch {
    private nonisolated static let ignoredNames: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData",
        "node_modules", ".DS_Store", "Pods",
        "xcuserdata", ".xcodeproj", ".xcworkspace",
    ]

    // File list cache keyed by project path. Populated once per project on first use
    // or proactively via prefetch(projectPath:). Filtering against the cached list is
    // cheap (in-memory), so typing after the first @ character is fast.
    private static var fileListCache: [String: [AtFileEntry]] = [:]
    private static var prefetchingPaths: Set<String> = []

    /// Pre-warms the file cache for a project in the background.
    /// Call when a project is selected so the cache is ready when the user types @.
    static func prefetch(projectPath: String) {
        guard fileListCache[projectPath] == nil, !prefetchingPaths.contains(projectPath) else { return }
        prefetchingPaths.insert(projectPath)
        Task {
            let files = await Task.detached(priority: .utility) {
                AtFileSearch.collectFiles(at: projectPath, basePath: projectPath, maxDepth: 6)
            }.value
            fileListCache[projectPath] = files
            prefetchingPaths.remove(projectPath)
        }
    }

    /// Invalidates the cached file list for a project (e.g. after file-tree changes).
    static func invalidate(for projectPath: String) {
        fileListCache.removeValue(forKey: projectPath)
    }

    static func search(query: String, projectPath: String, maxResults: Int = 20) -> [AtFileEntry] {
        // Use the cached file list; fall back to a synchronous scan only if the
        // prefetch hasn't finished yet (should be rare after the first project open).
        let allFiles: [AtFileEntry]
        if let cached = fileListCache[projectPath] {
            allFiles = cached
        } else {
            allFiles = collectFiles(at: projectPath, basePath: projectPath, maxDepth: 6)
            fileListCache[projectPath] = allFiles
        }

        let q = query.lowercased()
        guard !q.isEmpty else {
            return Array(allFiles.prefix(maxResults))
        }

        // Filename match takes priority, path match is secondary
        var nameMatches: [AtFileEntry] = []
        var pathMatches: [AtFileEntry] = []

        for entry in allFiles {
            if entry.name.lowercased().contains(q) {
                nameMatches.append(entry)
            } else if entry.relativePath.lowercased().contains(q) {
                pathMatches.append(entry)
            }
        }

        let combined = nameMatches + pathMatches
        return Array(combined.prefix(maxResults))
    }

    private nonisolated static func collectFiles(
        at path: String,
        basePath: String,
        maxDepth: Int,
        currentDepth: Int = 0
    ) -> [AtFileEntry] {
        guard currentDepth <= maxDepth else { return [] }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [AtFileEntry] = []

        for url in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = url.lastPathComponent
            if ignoredNames.contains(name) { continue }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                results += collectFiles(
                    at: url.path,
                    basePath: basePath,
                    maxDepth: maxDepth,
                    currentDepth: currentDepth + 1
                )
            } else {
                let relativePath = String(url.path.dropFirst(basePath.count + 1))
                let directory = (relativePath as NSString).deletingLastPathComponent
                results.append(AtFileEntry(
                    id: relativePath,
                    name: name,
                    directory: directory,
                    relativePath: relativePath
                ))
            }
        }

        return results
    }
}
#endif
