import Foundation

/// Extracts "owner/repo" from a GitHub remote URL.
/// Supports HTTPS and SSH formats.
/// Returns nil for non-GitHub URLs.
public func parseGitHubOwnerRepo(from urlString: String) -> String? {
    guard urlString.contains("github.com") else { return nil }
    let cleaned = urlString
        .replacingOccurrences(of: "https://github.com/", with: "")
        .replacingOccurrences(of: "http://github.com/", with: "")
        .replacingOccurrences(of: "git@github.com:", with: "")
        .replacingOccurrences(of: ".git", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    let parts = cleaned.split(separator: "/")
    guard parts.count >= 2 else { return nil }
    return "\(parts[0])/\(parts[1])"
}
