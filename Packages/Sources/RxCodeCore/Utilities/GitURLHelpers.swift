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

public func gitHubWebURL(forOwnerRepo ownerRepo: String) -> URL? {
    URL(string: "https://github.com/\(ownerRepo)")
}

public func detectGitHubOwnerRepo(at path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["remote", "get-url", "origin"]
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let urlString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !urlString.isEmpty else { return nil }

    return parseGitHubOwnerRepo(from: urlString)
}
