import Foundation

/// Parses `.env`-style files. Each non-empty, non-comment line is `KEY=VALUE`.
/// Quoted values (single or double) are unwrapped. Backslash escapes inside
/// double-quoted values are honored for `\n`, `\r`, `\t`, `\\`, `\"`. Inline
/// `#` inside an unquoted value is preserved (matches `dotenv`).
public enum RunEnvFileParser {

    /// Parse the raw text contents of a `.env` file.
    /// Returns ordered (key, value) tuples. Last duplicate key wins when
    /// merged into a dictionary.
    public static func parse(_ contents: String) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }
            let body: String
            if trimmed.hasPrefix("export ") {
                body = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            } else {
                body = trimmed
            }
            guard let eq = body.firstIndex(of: "=") else { continue }
            let key = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rawValue = String(body[body.index(after: eq)...])
            let value = unquote(rawValue)
            out.append((key, value))
        }
        return out
    }

    /// Parse and merge into an ordered dictionary preserving insertion order.
    /// Last write wins for duplicate keys.
    public static func parseAsDictionary(_ contents: String) -> [String: String] {
        var dict: [String: String] = [:]
        for (k, v) in parse(contents) { dict[k] = v }
        return dict
    }

    private static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        let first = trimmed.first
        let last = trimmed.last
        if first == "\"" && last == "\"" {
            let inner = String(trimmed.dropFirst().dropLast())
            return applyDoubleQuoteEscapes(inner)
        }
        if first == "'" && last == "'" {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func applyDoubleQuoteEscapes(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        while let c = iter.next() {
            if c == "\\" {
                if let next = iter.next() {
                    switch next {
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    default:
                        out.append("\\")
                        out.append(next)
                    }
                } else {
                    out.append("\\")
                }
            } else {
                out.append(c)
            }
        }
        return out
    }
}
