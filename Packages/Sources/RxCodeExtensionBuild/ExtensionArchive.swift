#if os(macOS)
import CExtensionArchive
import Darwin
import Foundation
import RxCodeCore
import RxCodeExtensionDistribution

public enum ExtensionArchive {
    /// The caller owns the newly created staging directory and removes it on failure.
    public static func stage(_ zip: URL, in directory: URL, envelope: ExtensionReleaseEnvelope,
                             keys: [String: Data], revocations: ExtensionRevocations?, requiresDeveloperID: Bool = false) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Read the same private copy for hashing and extraction.
        let copy = directory.appending(path: "release.zip")
        try fm.copyItem(at: zip, to: copy)
        try ExtensionReleaseVerifier.verify(archive: copy, envelope: envelope, keys: keys, revocations: revocations)
        let bundle = try extract(copy, into: directory)
        try fm.removeItem(at: copy)
        let service = bundle.appending(path: "Contents/Extensions/Service.appex")
        let resource = "Contents/Resources/" + ExtensionManifest.resourceName
        let manifestData = try Data(contentsOf: bundle.appending(path: resource))
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        try manifest.validate()
        guard manifest.id == envelope.id, manifest.version == envelope.version, manifest.pluginAPI == envelope.pluginApi,
              try Data(contentsOf: service.appending(path: resource)) == manifestData,
              try fm.contentsOfDirectory(atPath: service.deletingLastPathComponent().path) == ["Service.appex"],
              !fm.fileExists(atPath: bundle.appending(path: "Contents/PlugIns").path) else {
            throw ExtensionBuildError("The staged extension bundle differs from the signed release.")
        }
        try ExtensionCompiler.verifyContainer(bundle, requiresDeveloperID: requiresDeveloperID)
        guard try ExtensionCompiler.codeHashes(of: service) == envelope.cdhashes else {
            throw ExtensionVerificationError.codeHashMismatch
        }
        return bundle
    }

    private static func extract(_ zip: URL, into directory: URL) throws -> URL {
        let invalid = ExtensionBuildError("Invalid extension archive or unsafe archive entry.")
        guard let reader = archive_read_new() else { throw invalid }
        defer { archive_read_free(reader) }
        guard archive_read_support_format_zip_seekable(reader) == 0,
              archive_read_open_filename(reader, zip.path, 65536) == 0 else { throw invalid }
        var entry: OpaquePointer?
        var root: String?
        var seen = Set<String>()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 65536)
        let fm = FileManager.default
        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == 1 { break } // ARCHIVE_EOF
            guard status == 0, let entry, let raw = archive_entry_pathname_utf8(entry),
                  let name = String(validatingCString: raw), !name.hasPrefix("/"), !name.contains("\\"),
                  name.utf8.count <= 1024, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else { throw invalid }
            let path = name.hasSuffix("/") ? String(name.dropLast()) : name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard let first = parts.first, first.hasSuffix(".app"), !first.hasPrefix("."),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  root == nil || root == String(first), seen.count < 8192,
                  seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalid }
            root = String(first)
            let url = directory.appending(path: path)
            let type = archive_entry_filetype(entry)
            if type == S_IFDIR {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            guard type == S_IFREG, parts.count > 1 else { throw invalid }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let mode: mode_t = archive_entry_perm(entry) & 0o111 == 0 ? 0o644 : 0o755
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            guard fd >= 0 else { throw invalid }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            while true {
                let length = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                guard length >= 0 else { throw invalid }
                if length == 0 { break }
                total += length
                guard total <= 256 * 1024 * 1024 else { throw invalid }
                try handle.write(contentsOf: buffer.prefix(length))
            }
        }
        guard let root else { throw invalid }
        return directory.appending(path: root)
    }
}
#endif
