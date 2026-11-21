import Foundation

/// An outline of repository-relative Git paths. Folder IDs end in "/" so they
/// stay distinct when a file is replaced by a directory in the same diff.
public struct GitPathTree: Sendable {
    public struct Node: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let children: [Node]
        public let fileCount: Int

        public var isDirectory: Bool { !children.isEmpty }
        public var outlineChildren: [Node]? { isDirectory ? children : nil }
    }

    public let roots: [Node]
    public let folders: Set<String>

    public struct Row: Identifiable, Sendable {
        public var id: String { node.id }
        public let node: Node
        public let depth: Int
    }

    public init(paths: [String]) {
        var folders: Set<String> = []
        func build(_ paths: [Substring], prefix: String) -> [Node] {
            let groups = Dictionary(grouping: paths) { $0.prefix { $0 != "/" } }
            var nodes: [Node] = []
            for (component, entries) in groups {
                let path = prefix + component
                var descendants: [Substring] = []
                for entry in entries {
                    let rest = entry.dropFirst(component.count)
                    if rest.isEmpty || rest == "/" {
                        nodes.append(Node(id: path + rest, name: String(component), children: [], fileCount: 1))
                    } else {
                        descendants.append(rest.dropFirst())
                    }
                }
                if !descendants.isEmpty {
                    let folder = path + "/"
                    folders.insert(folder)
                    let children = build(descendants, prefix: folder)
                    nodes.append(Node(id: folder, name: String(component), children: children,
                                      fileCount: children.reduce(0) { $0 + $1.fileCount }))
                }
            }
            return nodes.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        roots = build(paths.map { $0[...] }, prefix: "")
        self.folders = folders
    }

    /// Resolve overlapping file and folder selections to individual files in display order.
    public func filePaths(in selection: Set<String>) -> [String] {
        guard !selection.isEmpty else { return [] }
        var result: [String] = []
        func visit(_ nodes: [Node], includeAll: Bool) {
            for node in nodes {
                let includesNode = includeAll || selection.contains(node.id)
                if node.isDirectory {
                    visit(node.children, includeAll: includesNode)
                } else if includesNode {
                    result.append(node.id)
                }
            }
        }
        visit(roots, includeAll: false)
        return result
    }

    public func visibleRows(collapsing collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        func append(_ nodes: [Node], depth: Int) {
            for node in nodes {
                rows.append(Row(node: node, depth: depth))
                if node.isDirectory, !collapsed.contains(node.id) { append(node.children, depth: depth + 1) }
            }
        }
        append(roots, depth: 0)
        return rows
    }
}
