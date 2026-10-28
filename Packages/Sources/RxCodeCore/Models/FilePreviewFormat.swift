import Foundation
import UniformTypeIdentifiers

/// Chooses a renderer without reading large media or document files into memory.
public enum FilePreviewFormat: Sendable, Equatable {
    case markdown
    case html
    case text
    case native

    public init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown": self = .markdown
        case "html", "htm", "xhtml": self = .html
        // These have a visual preview and a useful source representation.
        case "svg", "rtf": self = .native
        case "json", "jsonl", "yaml", "yml", "toml", "csv", "tsv", "xml",
             "log", "ini", "conf", "env", "gitignore", "dockerignore", "lock",
             "swift", "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "sh", "css", "sql": self = .text
        default:
            if let type = UTType(filenameExtension: ext), !type.isDynamic,
               !type.conforms(to: .text), !type.conforms(to: .sourceCode) {
                self = .native
            } else {
                // Unknown extensions and extensionless files are probed as text.
                self = .text
            }
        }
    }

    public var hasRenderedPreview: Bool { self != .text }

    public func canReadSource(fileName: String) -> Bool {
        self != .native || ["svg", "rtf"].contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Only decode lossless text; binary files must never become editable source.
    public static func decodeSource(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
