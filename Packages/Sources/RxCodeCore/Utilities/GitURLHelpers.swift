import Foundation

/// Extracts "owner/repo" from a GitHub remote URL.
/// Supports HTTPS and SSH formats.
/// Returns nil for non-GitHub URLs.
public func parseGitHubOwnerRepo(from urlString: String) -> String? {
    let remote = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    let sshPrefix = "git@github.com:"
    let path: String
    if remote.lowercased().hasPrefix(sshPrefix) {
        path = String(remote.dropFirst(sshPrefix.count))
    } else {
        guard let url = URLComponents(string: remote), let scheme = url.scheme?.lowercased(),
              ["https", "http", "ssh", "git"].contains(scheme),
              let host = url.host?.lowercased(), host == "github.com" || (scheme == "ssh" && host == "ssh.github.com")
        else { return nil }
        path = url.path
    }

    let parts = path.split(separator: "/")
    guard parts.count == 2 else { return nil }
    let repo = parts[1].hasSuffix(".git") ? parts[1].dropLast(4) : parts[1]
    let invalidCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").inverted
    guard [parts[0], repo].allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.rangeOfCharacter(from: invalidCharacters) == nil
    }) else { return nil }
    return "\(parts[0])/\(repo)"
}

public func gitHubWebURL(forOwnerRepo ownerRepo: String) -> URL? {
    URL(string: "https://github.com/\(ownerRepo)")
}

#if os(macOS)

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

#endif
