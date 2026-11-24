import CryptoKit
import Darwin
import Foundation
import ImageIO
import RxCodeCore
import Security
import UniformTypeIdentifiers

nonisolated struct AgentExtensionBuild: Sendable {
    let containerURL: URL
    let bundleIdentifier: String
    let teamIdentifier: String
    let generation: String
}

/// Compiles only a snapshot of the editable Swift file. Bundle metadata, compiler arguments,
/// entitlements, and the executable used for the containing application belong to the host.
nonisolated enum AgentExtensionBuilder {
    private static let maxSourceBytes = 512 * 1024
    private static let maxReadmeBytes = 256 * 1024
    private static let maxIconBytes = 2 * 1024 * 1024
    static let readmeFileName = "README.md"
    static let iconFileName = "icon.png"
    private static var hostID: String { Bundle.main.bundleIdentifier ?? "app.rxlab.flowcy.code" }

    static func serviceIdentifier(in workspace: URL, name: String) throws -> String {
        try validate(name)
        let path = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(hostID).development.w\(digest).\(name).service"
    }

    /// The installed container of a development extension built by this host, or nil for other identifiers.
    static func developmentContainer(forServiceIdentifier identifier: String) -> URL? {
        let prefix = "\(hostID).development.w", suffix = ".service"
        guard identifier.hasPrefix(prefix), identifier.hasSuffix(suffix) else { return nil }
        let parts = identifier.dropFirst(prefix.count).dropLast(suffix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 24, parts[0].allSatisfy(\.isHexDigit),
              (try? validate(String(parts[1]))) != nil else { return nil }
        return destination(for: identifier, name: String(parts[1]))
    }

    private static func validate(_ name: String) throws {
        guard name.utf8.count <= 48,
              name.range(of: #"\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z"#, options: .regularExpression) != nil else {
            throw IDEToolError.handlerFailed("Use a lowercase extension name starting with a letter, with up to 48 letters, digits, or hyphens between words.")
        }
    }

    static func create(in workspace: URL, name: String) throws -> URL {
        try validate(name)
        try withDirectory(in: workspace, name: name, create: true) { directory in
            for (file, contents) in [("Extension.swift", starterSource), (readmeFileName, starterReadme(name))] {
                let fd = openat(directory, file, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: Data(contents.utf8))
                try handle.close()
            }
        }
        return workspace.appending(path: ".rxcode/extensions/\(name)/Extension.swift")
    }

    // Keep directory handles while traversing. A workspace symlink must never redirect the
    // scaffold write or make the compiler read an unrelated source file.
    private static func withDirectory<T>(in workspace: URL, name: String, create: Bool, _ body: (Int32) throws -> T) throws -> T {
        var directory = open(workspace.standardizedFileURL.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        for (index, component) in [".rxcode", "extensions", name].enumerated() {
            if create && mkdirat(directory, component, 0o755) != 0 {
                guard errno == EEXIST else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                if index == 2 {
                    throw IDEToolError.handlerFailed("The extension directory already exists. Edit .rxcode/extensions/\(name)/Extension.swift and reload it.")
                }
            }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                throw IDEToolError.handlerFailed("Cannot open the extension directory. Create the extension in this workspace and use real directories under .rxcode/extensions.")
            }
            close(directory)
            directory = next
        }
        return try body(directory)
    }

    private static func source(in workspace: URL, name: String) throws -> Data {
        try withDirectory(in: workspace, name: name, create: false) { directory in
            guard let data = try readFile("Extension.swift", in: directory, name: name, maxBytes: maxSourceBytes) else {
                throw IDEToolError.handlerFailed("Cannot open .rxcode/extensions/\(name)/Extension.swift.")
            }
            return data
        }
    }

    struct PackagedResources: Sendable {
        var readme: Data?
        var icon: Data?
    }

    /// Optional README.md and icon.png that ship inside the built extension.
    static func resources(in workspace: URL, name: String) throws -> PackagedResources {
        try withDirectory(in: workspace, name: name, create: false) { directory in
            let readme = try readFile(readmeFileName, in: directory, name: name, maxBytes: maxReadmeBytes)
            if let readme, String(data: readme, encoding: .utf8) == nil {
                throw IDEToolError.handlerFailed("\(readmeFileName) must be UTF-8 text.")
            }
            let icon = try readFile(iconFileName, in: directory, name: name, maxBytes: maxIconBytes)
            if let icon, !icon.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                throw IDEToolError.handlerFailed("\(iconFileName) must be a PNG image. Use a square image, ideally 1024×1024.")
            }
            return PackagedResources(readme: readme, icon: icon)
        }
    }

    /// Reads a regular file inside the extension directory. Returns nil only when the file does not exist.
    private static func readFile(_ file: String, in directory: Int32, name: String, maxBytes: Int) throws -> Data? {
        let fd = openat(directory, file, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw IDEToolError.handlerFailed("Cannot open .rxcode/extensions/\(name)/\(file).")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .binary)
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= maxBytes else {
            throw IDEToolError.handlerFailed("\(file) must be a regular file of at most \(limit).")
        }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw IDEToolError.handlerFailed("\(file) exceeds \(limit).") }
        return data
    }

    static func resolveSigningIdentity(in workspace: URL, name: String, requested: String?) async throws -> String {
        let serviceID = try serviceIdentifier(in: workspace, name: name)
        return try await signingCertificate(requested: requested, previous: destination(for: serviceID, name: name))
    }

    private static func destination(for serviceID: String, name: String) -> URL {
        let containerID = serviceID.dropLast(".service".count)
        return AppSupport.bundleScopedURL.appending(path: "DevelopmentExtensions/\(containerID)/\(name).app")
    }

    static func build(in workspace: URL, name: String, signingIdentity: String? = nil) async throws -> AgentExtensionBuild {
        let serviceID = try serviceIdentifier(in: workspace, name: name)
        let containerID = String(serviceID.dropLast(".service".count))
        let source = try source(in: workspace, name: name)
        let resources = try resources(in: workspace, name: name)
        let destination = destination(for: serviceID, name: name)
        let builds = destination.deletingLastPathComponent()
        let signer = try await signingCertificate(requested: signingIdentity, previous: destination)
        let generation = UUID().uuidString
        let fm = FileManager.default
        let staging = builds.appending(path: ".building-\(generation)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let container = staging.appending(path: "Contributor.app")
        let service = container.appending(path: "Contents/Extensions/Service.appex")
        let serviceBinary = service.appending(path: "Contents/MacOS/Service")
        let containerBinary = container.appending(path: "Contents/MacOS/Contributor")
        for binary in [serviceBinary, containerBinary] {
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let previousInfo = (try? Data(contentsOf: destination.appending(path: "Contents/Info.plist"))).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let buildNumber = (Int(previousInfo?["CFBundleVersion"] as? String ?? "0") ?? 0) + 1
        let version = String(buildNumber)
        var info: [String: Any] = ["CFBundleInfoDictionaryVersion": "6.0", "CFBundleSupportedPlatforms": ["MacOSX"],
                                   "LSMinimumSystemVersion": "26.0", "CFBundleShortVersionString": "1.0", "CFBundleVersion": version,
                                   "CFBundleName": name, "CFBundleDisplayName": name, "CFBundleExecutable": "Contributor",
                                   "CFBundleIdentifier": containerID, "CFBundlePackageType": "APPL",
                                   ExtensionPluginAPI.infoPlistKey: ExtensionPluginAPI.version]
        try packageResources(resources, container: container, service: service)
        if fm.fileExists(atPath: container.appending(path: "Contents/Resources/AppIcon.icns").path) {
            info["CFBundleIconFile"] = "AppIcon"
        }
        try writePlist(info, to: container.appending(path: "Contents/Info.plist"))
        info["CFBundleIconFile"] = nil
        info["CFBundleExecutable"] = "Service"
        info["CFBundleIdentifier"] = serviceID
        info["CFBundlePackageType"] = "XPC!"
        info["EXAppExtensionAttributes"] = ["EXExtensionPointIdentifier": "\(hostID).workspace-service"]
        info["RxCodeDevelopmentGeneration"] = generation
        try writePlist(info, to: service.appending(path: "Contents/Info.plist"))
        let entitlement = staging.appending(path: "Service.entitlements")
        try writePlist(["com.apple.security.app-sandbox": true], to: entitlement)
        let swift = staging.appending(path: "Extension.swift"), bridge = staging.appending(path: "Service.swift")
        try source.write(to: swift)
        try Self.bridge(generation).write(to: bridge, atomically: true, encoding: .utf8)
        let main = staging.appending(path: "Contributor.c")
        try "int main(void) { return 0; }\n".write(to: main, atomically: true, encoding: .utf8)
        #if arch(arm64)
        let target = "arm64-apple-macosx26.0"
        #else
        let target = "x86_64-apple-macosx26.0"
        #endif
        _ = try await DesignCommand.run("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc", "-target", target, "-parse-as-library",
            "-application-extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", swift.path, bridge.path, "-o", serviceBinary.path], timeout: 120)
        _ = try await DesignCommand.run("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-target", target, main.path, "-o", containerBinary.path])
        let signing = ["--sign", signer, "--force", "--options", "runtime", "--timestamp=none"]
        _ = try await DesignCommand.run("/usr/bin/codesign", signing + ["--entitlements", entitlement.path, service.path])
        _ = try await DesignCommand.run("/usr/bin/codesign", signing + [container.path])
        _ = try await DesignCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", container.path])
        guard let team = signature(of: service)?.team else { throw IDEToolError.handlerFailed("The signed extension is missing its team identifier.") }
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: container, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: container, to: destination)
        }
        return AgentExtensionBuild(containerURL: destination, bundleIdentifier: serviceID, teamIdentifier: team, generation: generation)
    }

    /// Copies README.md and Icon.png into both bundles so either can be inspected on its own.
    /// The container also gets an .icns so the macOS extension manager shows the icon.
    private static func packageResources(_ resources: PackagedResources, container: URL, service: URL) throws {
        let fm = FileManager.default
        for bundle in [container, service] {
            let folder = bundle.appending(path: "Contents/Resources")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let readme = resources.readme { try readme.write(to: folder.appending(path: InstalledExtensionMetadata.readmeFileName)) }
            if let icon = resources.icon { try icon.write(to: folder.appending(path: InstalledExtensionMetadata.iconFileName)) }
        }
        guard let icon = resources.icon, let icns = icns(fromPNG: icon) else { return }
        try icns.write(to: container.appending(path: "Contents/Resources/AppIcon.icns"))
    }

    /// Builds an .icns with the standard macOS app icon sizes from one PNG.
    static func icns(fromPNG png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let entries: [(type: String, pixels: Int)] = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                                                      ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
        var body = Data()
        for entry in entries {
            guard let scaled = pngData(image, pixels: entry.pixels) else { return nil }
            body.append(Data(entry.type.utf8))
            body.append(bigEndian(UInt32(scaled.count + 8)))
            body.append(scaled)
        }
        var file = Data("icns".utf8)
        file.append(bigEndian(UInt32(body.count + 8)))
        file.append(body)
        return file
    }

    private static func pngData(_ image: CGImage, pixels: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Fit non-square artwork inside the square canvas without distortion.
        let scale = min(CGFloat(pixels) / CGFloat(image.width), CGFloat(pixels) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                                       width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func writePlist(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }

    private static func signature(of bundle: URL) -> (hash: String, team: String)? {
        var code: SecStaticCode?, dictionary: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let cert = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02X", $0) }.joined()
        return (hash, team)
    }

    private static func signingCertificate(requested: String?, previous: URL) async throws -> String {
        let output = try await DesignCommand.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        let identities = String(decoding: output, as: UTF8.self).components(separatedBy: .newlines).compactMap { line -> (hash: String, name: String)? in
            let fields = line.components(separatedBy: "\"")
            guard fields.count == 3, fields[1].hasPrefix("Developer ID Application:") || fields[1].hasPrefix("Apple Development:"),
                  let hash = fields[0].split(whereSeparator: \.isWhitespace).last,
                  hash.count == 40, hash.allSatisfy(\.isHexDigit) else { return nil }
            return (String(hash), fields[1])
        }
        guard !identities.isEmpty else { throw IDEToolError.handlerFailed("Install an Apple Development or Developer ID Application signing identity with its private key to load a native extension.") }
        if let requested {
            let matches = identities.filter { $0.hash == requested.uppercased() || $0.name == requested }
            if matches.count == 1 { return matches[0].hash }
        } else if let preferred = signature(of: previous) ?? signature(of: Bundle.main.bundleURL) {
            if identities.contains(where: { $0.hash == preferred.hash }) { return preferred.hash }
            let matches = identities.filter { $0.name.hasSuffix("(\(preferred.team))") }
            if matches.count == 1 { return matches[0].hash }
        } else if identities.count == 1 {
            return identities[0].hash
        }
        let choices = identities.map { "\($0.hash) \($0.name)" }.joined(separator: "\n")
        throw IDEToolError.handlerFailed("Choose a signing_identity from the installed certificates and reload again.\n\(choices)")
    }

    static let starterSource = """
        import Foundation

        enum WorkspaceExtension {
            static func runTest(_ input: String) -> String {
                input
            }
        }

        """

    static func starterReadme(_ name: String) -> String {
        """
        # \(name)

        Describe what this extension does. RxCode shows this README in Settings → Extensions.

        ## Usage

        Send text to the extension with `ide__test_extension`. It returns the result of `WorkspaceExtension.runTest(_:)`.

        ## Icon

        Add a square PNG named `icon.png` (1024×1024 recommended) next to this file. RxCode packages it on the next reload.

        """
    }

    private static func bridge(_ generation: String) -> String {
        """
        import ExtensionFoundation
        import Foundation
        import XPC

        @main struct Contributor: AppExtension {
            var configuration: some AppExtensionConfiguration {
                ConnectionHandler { (request: XPCListener.IncomingSessionRequest) in
                    request.accept { (message: [String: String]) -> (any Encodable)? in
                        switch message["operation"] {
                        case "generation":
                            let installed = Bundle.main.object(forInfoDictionaryKey: "RxCodeDevelopmentGeneration") as? String
                            return ["value": installed == "\(generation)" ? "\(generation)" : ""]
                        case "test":
                            guard let input = message["input"] else { return ["error": "Missing test input."] }
                            return ["value": WorkspaceExtension.runTest(input)]
                        default:
                            return ["error": "Unknown extension request."]
                        }
                    }
                }
            }
        }
        """
    }
}
