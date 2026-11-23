import Foundation

#if os(macOS)
/// An editable snapshot of the root .gitignore in a single worktree.
public struct GitIgnoreFile: Sendable {
    private static let writeLock = NSLock()
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    private let url: URL
    private let original: Data?
    public let text: String

    @concurrent public static func load(at root: String) async throws -> Self {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".gitignore")
        let original = try read(at: url)
        let bytes = original ?? Data()
        let content = bytes.starts(with: byteOrderMark) ? bytes.dropFirst(byteOrderMark.count) : bytes
        guard let text = String(data: content, encoding: .utf8) else { throw Failure.invalidEncoding }
        return Self(url: url, original: original, text: text)
    }

    /// Paths come from the Git tree, where folder paths already have a trailing slash.
    public static func literalPattern(for path: String) -> String? {
        // A single ignore rule cannot express a filename containing a line break.
        guard !path.isEmpty, !path.utf8.contains(0x0A), !path.utf8.contains(0x0D) else { return nil }
        let escaped = path.unicodeScalars.flatMap { scalar -> [Unicode.Scalar] in
            switch scalar {
            case "\\", "*", "?", "[", "]", " ": ["\\", scalar]
            default: [scalar]
            }
        }
        return "/" + String(String.UnicodeScalarView(escaped))
    }

    public func adding(_ patterns: [String]) -> String {
        guard !patterns.isEmpty else { return text }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let addition = patterns.joined(separator: newline)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let existing = lines.last?.isEmpty == true ? lines.dropLast() : lines[...]
        if existing.suffix(patterns.count).elementsEqual(patterns.map { $0[...] }) { return text }
        let separator = text.isEmpty || text.utf8.last == 0x0A ? "" : newline
        return text + separator + addition + newline
    }

    @concurrent public func save(_ updatedText: String) async throws -> Self {
        try Self.writeLock.withLock {
            guard try Self.read(at: url) == original else { throw Failure.changedOnDisk }
            var data = Data()
            if original?.starts(with: Self.byteOrderMark) == true { data.append(contentsOf: Self.byteOrderMark) }
            data.append(contentsOf: updatedText.utf8)
            try data.write(to: url, options: .atomic)
            return Self(url: url, original: data, text: updatedText)
        }
    }

    public static func ignoredPaths(at root: String) async throws -> [String] {
        let output = await GitHelper.execute(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], at: root)
        guard let output, output.status == 0 else { throw Failure.listFailed(output?.combinedTrimmed) }
        return output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func read(at url: URL) throws -> Data? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.notRegularFile }
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private enum Failure: LocalizedError {
        case invalidEncoding, changedOnDisk, notRegularFile, listFailed(String?)

        var errorDescription: String? {
            switch self {
            case .invalidEncoding: String(localized: ".gitignore must be UTF-8 to open in this editor.")
            case .changedOnDisk: String(localized: ".gitignore changed on disk. Reopen the editor to load the latest version.")
            case .notRegularFile: String(localized: ".gitignore must be a regular file.")
            case .listFailed(let detail): detail.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Couldn’t list ignored files.")
            }
        }
    }
}
#endif
