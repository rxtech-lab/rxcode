import Foundation

/// Finds images in a briefing body that only exist on this Mac, so they can be
/// uploaded as Autopilot notification attachments and the references swapped
/// for `{{attachment:<id>}}` placeholders the server renders inline.
///
/// Recognized references:
/// - Markdown images: `![alt](images/chart.png)` or `![alt](<path> "title")`
/// - HTML images: `<img src="images/chart.png" …>`
///
/// Remote (`http(s):`) and inline `data:` sources are left alone.
public enum NotificationBodyImages {

    /// One local image occurrence in the body.
    public struct Reference: Equatable, Sendable {
        /// The full matched markup, replaced as a whole.
        public let markup: String
        /// The source path or URL exactly as written.
        public let source: String
        /// The alt text, used when the image can't be uploaded.
        public let altText: String
        /// The resolved file on disk.
        public let fileURL: URL
    }

    private static let markdownImage = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
    )
    private static let htmlImage = try! NSRegularExpression(
        pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let htmlAlt = try! NSRegularExpression(
        pattern: #"\balt\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
        options: [.caseInsensitive]
    )

    /// Every local image reference in `body`, in document order. Relative
    /// paths resolve against `baseURL` (the briefing folder); files that
    /// don't exist are skipped.
    public static func references(
        in body: String,
        format: BriefingContentFormat,
        baseURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [Reference] {
        let range = NSRange(body.startIndex..., in: body)
        var found: [(location: Int, reference: Reference)] = []

        // HTML <img> tags are valid inside Markdown too.
        for match in htmlImage.matches(in: body, range: range) {
            guard let markup = substring(body, match.range),
                  let source = substring(body, match.range(at: 1)) ?? substring(body, match.range(at: 2)),
                  let url = resolve(source, baseURL: baseURL), fileExists(url)
            else { continue }
            found.append((match.range.location, Reference(
                markup: markup, source: source, altText: htmlAltText(markup), fileURL: url
            )))
        }
        if format == .markdown {
            for match in markdownImage.matches(in: body, range: range) {
                guard let markup = substring(body, match.range),
                      var source = substring(body, match.range(at: 2))
                else { continue }
                if source.hasPrefix("<"), source.hasSuffix(">") {
                    source = String(source.dropFirst().dropLast())
                }
                guard let url = resolve(source, baseURL: baseURL), fileExists(url) else { continue }
                found.append((match.range.location, Reference(
                    markup: markup, source: source, altText: substring(body, match.range(at: 1)) ?? "", fileURL: url
                )))
            }
        }
        return found.sorted { $0.location < $1.location }.map(\.reference)
    }

    /// Replaces each reference's markup with its placeholder. References
    /// missing from `attachmentIds` (not uploaded) fall back to their alt
    /// text so the body never points at a file the recipient can't open.
    public static func replacing(
        _ references: [Reference],
        in body: String,
        attachmentIds: [URL: String]
    ) -> String {
        var result = body
        for reference in references {
            let replacement: String
            if let id = attachmentIds[reference.fileURL] {
                replacement = placeholder(for: id)
            } else {
                replacement = reference.altText
            }
            result = result.replacingOccurrences(of: reference.markup, with: replacement)
        }
        return result
    }

    /// The server's marker for an embedded attachment.
    public static func placeholder(for attachmentId: String) -> String {
        "{{attachment:\(attachmentId)}}"
    }

    // MARK: - Helpers

    /// Resolves a written source to a local file URL, or nil for remote,
    /// inline, anchor, or otherwise non-file sources.
    static func resolve(_ rawSource: String, baseURL: URL) -> URL? {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.hasPrefix("#") else { return nil }
        let lowered = source.lowercased()
        if lowered.hasPrefix("file://") {
            return URL(string: source)?.standardizedFileURL
        }
        // Any other scheme (http:, https:, data:, cid:, …) is not a local file.
        if let colon = source.firstIndex(of: ":"),
           source[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
           source[..<colon].count > 1 {
            return nil
        }
        let decoded = source.removingPercentEncoding ?? source
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded).standardizedFileURL
        }
        if decoded.hasPrefix("~") {
            return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath).standardizedFileURL
        }
        return baseURL.appendingPathComponent(decoded).standardizedFileURL
    }

    private static func htmlAltText(_ markup: String) -> String {
        let range = NSRange(markup.startIndex..., in: markup)
        guard let match = htmlAlt.firstMatch(in: markup, range: range) else { return "" }
        return substring(markup, match.range(at: 1)) ?? substring(markup, match.range(at: 2)) ?? ""
    }

    private static func substring(_ string: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else { return nil }
        return String(string[swiftRange])
    }
}
