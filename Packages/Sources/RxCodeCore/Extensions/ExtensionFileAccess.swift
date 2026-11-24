import Darwin
import Foundation

/// Captures the window's project or worktree directory at connection time. All child
/// lookups are relative to open directory descriptors, including directory listings.
public final class ExtensionFileAccess: Sendable {
    public enum Failure: Error, Equatable { case denied, invalidPath, tooLarge }
    private let project: FileHandle
    private let rootPath: String

    public init(projectRoot: URL) throws {
        guard projectRoot.isFileURL else { throw Failure.invalidPath }
        let path = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.posixError() }
        project = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        rootPath = try Self.resolvedPath(fd)
    }

    public func read(_ path: String, diskReadGranted: Bool = false) throws -> Data {
        let handle = try openPath(path, directory: false, unrestricted: diskReadGranted)
        let limit = 20 * 1024 * 1024
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw Self.posixError() }
        guard info.st_size <= limit else { throw Failure.tooLarge }
        var result = Data()
        while let bytes = try handle.read(upToCount: min(limit + 1 - result.count, 64 * 1024)), !bytes.isEmpty {
            result.append(bytes)
            guard result.count <= limit else { throw Failure.tooLarge }
        }
        return result
    }

    public func list(_ path: String, diskReadGranted: Bool = false) throws -> [String] {
        let handle = try openPath(path, directory: true, unrestricted: diskReadGranted)
        let fd = dup(handle.fileDescriptor)
        guard fd >= 0 else { throw Self.posixError() }
        guard let stream = fdopendir(fd) else {
            let error = Self.posixError()
            close(fd)
            throw error
        }
        defer { closedir(stream) }
        let parent = path.split(separator: "/").map(String.init)
        var names: [String] = []
        var size = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.posixError() }
                break
            }
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, {
                String(validatingCString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }), name != ".", name != ".." else { continue }
            if !diskReadGranted && Self.isSensitive(parent + [name]) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.allowed(info, unrestricted: diskReadGranted) else { continue }
            size += name.utf8.count + 1
            guard names.count < 100_000, size <= 20 * 1024 * 1024 else { throw Failure.tooLarge }
            names.append(name)
        }
        return names.sorted()
    }

    private func openPath(_ path: String, directory: Bool, unrestricted: Bool) throws -> FileHandle {
        guard !path.utf8.contains(0), unrestricted || !path.hasPrefix("/") else { throw Failure.invalidPath }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") || path == "." else { throw Failure.invalidPath }
        guard directory || !components.isEmpty else { throw Failure.invalidPath }
        guard unrestricted || !Self.isSensitive(components) else { throw Failure.denied }
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let base = path.hasPrefix("/") ? open("/", flags | O_DIRECTORY) : openat(project.fileDescriptor, ".", flags | O_DIRECTORY)
        guard base >= 0 else { throw Self.posixError() }
        var current = FileHandle(fileDescriptor: base, closeOnDealloc: true)
        for (index, name) in components.enumerated() {
            let requireDirectory = directory || index < components.count - 1
            let fd = openat(current.fileDescriptor, name, flags | (requireDirectory ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw Self.posixError() }
            current = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        var info = stat()
        guard fstat(current.fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              Self.allowed(info, unrestricted: unrestricted) else { throw Failure.denied }
        if !unrestricted {
            let actual = try Self.resolvedPath(current.fileDescriptor)
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            guard actual == rootPath || actual.hasPrefix(prefix) else { throw Failure.denied }
            let relative = actual.dropFirst(rootPath.count)
            guard !Self.isSensitive(relative.split(separator: "/").map(String.init)) else { throw Failure.denied }
        }
        return current
    }

    private static func allowed(_ info: stat, unrestricted: Bool) -> Bool {
        switch info.st_mode & S_IFMT {
        case S_IFDIR: true
        // A harmless-looking name may be a hard link to a protected file. The
        // descriptor cannot prove the names of its other links.
        case S_IFREG: unrestricted || info.st_nlink == 1
        default: false
        }
    }

    static func isSensitive(_ components: [String]) -> Bool {
        let names = components.map { $0.lowercased() }
        for (index, name) in names.enumerated() {
            if [".ssh", ".aws", ".gnupg", ".netrc", ".npmrc", ".pypirc"].contains(name) { return true }
            if name == ".env" || name.hasPrefix(".env.") {
                if ![".env.example", ".env.sample", ".env.template"].contains(name) { return true }
            }
            if [".pem", ".key", ".p12", ".p8"].contains(where: name.hasSuffix)
                || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.contains(".keychain") {
                return true
            }
            if index > 0 && ((names[index - 1] == ".git" && name == "config")
                || (names[index - 1] == ".rxcode" && name == "secrets")) { return true }
        }
        return false
    }

    private static func resolvedPath(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw posixError() }
        guard let path = buffer.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) else {
            throw Failure.invalidPath
        }
        return path
    }

    private static func posixError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
}
