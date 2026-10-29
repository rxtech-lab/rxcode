import Foundation

public struct LocalFileLink: Sendable, Equatable, Identifiable {
    public var id: String { line.map { "\(path):\($0)" } ?? path }

    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }

    public static func parse(_ url: URL) -> LocalFileLink? {
        let raw = localPathString(from: url)
        return raw.flatMap(parsePathString)
    }

    public static func parsePathString(_ value: String) -> LocalFileLink? {
        let decoded = value.removingPercentEncoding ?? value
        let trimmed = unwrappedMarkdownPath(decoded.trimmingCharacters(in: .whitespacesAndNewlines))
        guard trimmed.hasPrefix("/") else { return nil }

        let parsed = stripLocationSuffix(from: trimmed)
        guard parsed.path.hasPrefix("/") else { return nil }

        let standardized = URL(fileURLWithPath: parsed.path)
            .standardizedFileURL
            .path
        return LocalFileLink(path: standardized, line: parsed.line, column: parsed.column)
    }

    /// Some Markdown renderers resolve `<...>` destinations as relative file
    /// URLs before delivering them, producing `/base/</absolute/path>`.
    /// Recover only a complete wrapper around an absolute path, never a lone
    /// angle bracket that could legitimately be part of the filename.
    private static func unwrappedMarkdownPath(_ value: String) -> String {
        guard value.hasSuffix(">") else { return value }
        if value.hasPrefix("</") {
            return String(value.dropFirst().dropLast())
        }
        if let wrapper = value.range(of: "/</") {
            return "/" + String(value[wrapper.upperBound...].dropLast())
        }
        return value
    }

    private static func localPathString(from url: URL) -> String? {
        if url.isFileURL {
            return url.path
        }

        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = url.host?.lowercased(),
           host == "users" {
            return "/Users" + url.path
        }

        if url.scheme == nil || url.scheme?.isEmpty == true {
            return url.relativeString.isEmpty ? url.absoluteString : url.relativeString
        }

        let absolute = url.absoluteString
        if absolute.hasPrefix("/") {
            return absolute
        }

        return nil
    }

    private static func stripLocationSuffix(from value: String) -> (path: String, line: Int?, column: Int?) {
        let firstPass = stripTrailingNumber(from: value)
        guard let lastNumber = firstPass.number else {
            return (value, nil, nil)
        }

        let secondPass = stripTrailingNumber(from: firstPass.path)
        if let lineNumber = secondPass.number {
            return (secondPass.path, lineNumber, lastNumber)
        }
        return (firstPass.path, lastNumber, nil)
    }

    private static func stripTrailingNumber(from value: String) -> (path: String, number: Int?) {
        guard let colon = value.lastIndex(of: ":") else {
            return (value, nil)
        }

        let suffix = value[value.index(after: colon)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let number = Int(suffix) else {
            return (value, nil)
        }

        return (String(value[..<colon]), number)
    }
}
