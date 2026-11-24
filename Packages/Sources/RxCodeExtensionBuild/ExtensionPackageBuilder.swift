#if os(macOS)
import CryptoKit
import Foundation
import RxCodeCore

public enum ExtensionPackageBuilder {
    public struct ReleaseMetadata: Codable {
        public let id: String
        public let version: String
        public let pluginApi: String
        public let sha256: String
        public let cdhashes: String
        public let sourceDigest: String
        public let size: Int
    }

    public static func build(directory: URL, output: URL, signer: String) throws {
        try build(files: ExtensionFileAccess(projectRoot: directory), prefix: "", output: output, signer: signer)
    }

    /// Development builds use a worktree-bound descriptor and a different container ID.
    public static func build(files: ExtensionFileAccess, prefix: String, output: URL, signer: String,
                             developmentID: String? = nil, generation: String? = nil,
                             workspacePoint: String = "app.rxlab.flowcy.code.workspace") throws {
        let fm = FileManager.default
        let rawManifest = try files.read(prefix + "extension.json")
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: rawManifest)
        try manifest.validate()
        var inputs = ["extension.json": rawManifest, "README.md": try files.read(prefix + manifest.readme)]
        let filesAtRoot = try files.list(prefix.isEmpty ? "." : prefix)
        if filesAtRoot.contains("icon.png") { inputs["icon.png"] = try files.read(prefix + "icon.png") }
        let catalog = "Resources/Localizable.xcstrings"
        if filesAtRoot.contains("Resources"), try files.list(prefix + "Resources").contains("Localizable.xcstrings") {
            inputs[catalog] = try files.read(prefix + catalog)
        }
        let sdkCatalog = try Data(contentsOf: ExtensionCompiler.sdkDirectory().appending(path: catalog))
        inputs["SDK/" + catalog] = sdkCatalog
        var sourceNames: [String] = []
        if filesAtRoot.contains("Sources") {
            sourceNames = try files.list(prefix + "Sources").filter { $0.hasSuffix(".swift") }.map { "Sources/" + $0 }
        }
        if filesAtRoot.contains("Extension.swift") { sourceNames.append("Extension.swift") }
        guard Set(sourceNames.map { URL(fileURLWithPath: $0).lastPathComponent }).count == sourceNames.count else {
            throw ExtensionBuildError("Swift files must have distinct filenames.")
        }
        guard !sourceNames.isEmpty else { throw ExtensionBuildError("Sources must contain Swift source files.") }
        for name in sourceNames {
            inputs[name] = try files.read(prefix + name)
        }
        let parent = output.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".building-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let app = staging.appending(path: "Contributor.app")
        let appex = app.appending(path: "Contents/Extensions/Service.appex")
        for bundle in [app, appex] {
            try fm.createDirectory(at: bundle.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            let resources = bundle.appending(path: "Contents/Resources")
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try rawManifest.write(to: resources.appending(path: ExtensionManifest.resourceName))
            try inputs["README.md"]?.write(to: resources.appending(path: "README.md"))
            try inputs["icon.png"]?.write(to: resources.appending(path: "Icon.png"))
        }
        let sources = staging.appending(path: "Sources")
        try fm.createDirectory(at: sources, withIntermediateDirectories: false)
        let sceneResources = appex.appending(path: "Contents/Resources")
        try compileCatalog(sdkCatalog, input: staging.appending(path: "RxCodeExtensionSDK.xcstrings"), output: sceneResources)
        if let strings = inputs[catalog] {
            try compileCatalog(strings, input: staging.appending(path: "Localizable.xcstrings"), output: sceneResources)
        }
        let isolatedSources = try sourceNames.map { name in
            let isolated = sources.appending(path: URL(fileURLWithPath: name).lastPathComponent)
            try inputs[name]?.write(to: isolated)
            return isolated
        }
        let cSource = staging.appending(path: "Contributor.c")
        try Data("int main(void) { return 0; }".utf8).write(to: cSource)
        try ExtensionCompiler.compile(serviceSources: isolatedSources,
                                      containerSource: cSource, serviceBinary: appex.appending(path: "Contents/MacOS/Service"),
                                      containerBinary: app.appending(path: "Contents/MacOS/Contributor"), staging: staging, includeSDK: true)
        for url in try ExtensionCompiler.sdkSources() { inputs["SDK/" + url.lastPathComponent] = try Data(contentsOf: url) }
        var info: [String: Any] = [
            "CFBundleIdentifier": developmentID ?? manifest.id, "CFBundleVersion": "1", "CFBundleShortVersionString": manifest.version,
            "CFBundleDisplayName": manifest.name, "CFBundleName": manifest.name, "CFBundleExecutable": "Contributor",
            "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "26.0", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "LSBackgroundOnly": true, "RxCodePluginAPIVersion": manifest.pluginAPI, "RxCodeSourceDigest": digest(inputs),
        ]
        try writePlist(info, to: app.appending(path: "Contents/Info.plist"))
        info["LSBackgroundOnly"] = nil
        info["CFBundleIdentifier"] = (developmentID ?? manifest.id) + ".service"
        info["RxCodeDevelopmentGeneration"] = generation
        info["CFBundlePackageType"] = "XPC!"
        info["CFBundleExecutable"] = "Service"
        info["EXAppExtensionAttributes"] = ["EXExtensionPointIdentifier": workspacePoint]
        try writePlist(info, to: appex.appending(path: "Contents/Info.plist"))
        let entitlements = staging.appending(path: "Sandbox.plist")
        try writePlist(["com.apple.security.app-sandbox": true], to: entitlements)
        let options = ["--force", "--sign", signer, "--options", "runtime", signer == "-" ? "--timestamp=none" : "--timestamp"]
        try ExtensionCompiler.run("/usr/bin/codesign", options + ["--entitlements", entitlements.path, appex.path])
        try ExtensionCompiler.run("/usr/bin/codesign", options + [app.path])
        try ExtensionCompiler.run("/usr/bin/codesign", ["--verify", "--all-architectures", "--strict", "--deep", app.path])
        _ = try ExtensionCompiler.codeHashes(of: appex)
        try fm.moveItem(at: app, to: output)
    }

    public static func package(bundle: URL, archive: URL) throws -> ReleaseMetadata {
        let data = try Data(contentsOf: bundle.appending(path: "Contents/Resources/" + ExtensionManifest.resourceName))
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
        try manifest.validate()
        let appex = bundle.appending(path: "Contents/Extensions/Service.appex")
        guard try Data(contentsOf: appex.appending(path: "Contents/Resources/" + ExtensionManifest.resourceName)) == data else {
            throw ExtensionBuildError("The packaged manifests differ.")
        }
        let info = try Data(contentsOf: bundle.appending(path: "Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let sourceDigest = plist["RxCodeSourceDigest"] as? String, sourceDigest.count == 64 else {
            throw ExtensionBuildError("The contributor is missing its build input digest.")
        }
        try ExtensionCompiler.run("/usr/bin/codesign", ["--verify", "--all-architectures", "--strict", "--deep", bundle.path])
        let hashes = try ExtensionCompiler.codeHashes(of: appex)
        let tempZip = archive.deletingLastPathComponent().appending(path: UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: tempZip) }
        try ExtensionCompiler.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", bundle.path, tempZip.path])
        let bytes = try Data(contentsOf: tempZip, options: .mappedIfSafe)
        guard bytes.count <= 50 * 1024 * 1024 else { throw ExtensionBuildError("The archive exceeds 50 MB.") }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.moveItem(at: tempZip, to: archive)
        return ReleaseMetadata(id: manifest.id, version: manifest.version, pluginApi: manifest.pluginAPI, sha256: hash,
                               cdhashes: hashes, sourceDigest: sourceDigest, size: bytes.count)
    }

    private static func writePlist(_ info: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
    }

    private static func compileCatalog(_ data: Data, input: URL, output: URL) throws {
        // Locale identifiers become output directory names. Validate them before invoking the compiler.
        struct Catalog: Decodable {
            struct Entry: Decodable { let localizations: [String: Ignore]? }
            struct Ignore: Decodable {}
            let sourceLanguage: String
            let strings: [String: Entry]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var languages = Set([catalog.sourceLanguage])
        for entry in catalog.strings.values {
            if let localizations = entry.localizations { languages.formUnion(localizations.keys) }
        }
        guard languages.allSatisfy({ $0.range(of: #"\A[A-Za-z][A-Za-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil }) else {
            throw ExtensionBuildError("The string catalog contains an invalid language identifier.")
        }
        try data.write(to: input)
        try ExtensionCompiler.run("/usr/bin/xcrun", ["xcstringstool", "compile", input.path, "--output-directory", output.path,
                                                    "--serialization-format", "binary"])
    }

    private static func digest(_ inputs: [String: Data]) -> String {
        var hash = SHA256()
        for name in inputs.keys.sorted() {
            hash.update(data: Data(name.utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(SHA256.hash(data: inputs[name]!)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
#endif
