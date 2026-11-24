#if os(macOS)
import CryptoKit
import Foundation
import RxCodeExtensionBuild
import RxCodeExtensionDistribution
import Testing

@Suite struct ExtensionArchiveTests {
    @Test func stageRequiresMatchingManifestsSandboxAndBothSignedCodeHashes() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let source = root.appending(path: "Example")
        let sources = source.appending(path: "Sources")
        try files.createDirectory(at: sources, withIntermediateDirectories: true)
        let manifest = """
        {"id":"app.rxlab.extensions.archive-fixture","name":"Archive fixture","version":"1.2.0",
         "pluginAPI":"2.0","permissions":[],"contributes":{},"readme":"README.md"}
        """
        try Data(manifest.utf8).write(to: source.appending(path: "extension.json"))
        try Data("Archive fixture".utf8).write(to: source.appending(path: "README.md"))
        let catalogs = source.appending(path: "Resources")
        try files.createDirectory(at: catalogs, withIntermediateDirectories: false)
        let strings = """
        {"sourceLanguage":"en","version":"1.0","strings":{
          "Account":{"localizations":{"fr":{"stringUnit":{"state":"translated","value":"Compte"}}}}
        }}
        """
        try Data(strings.utf8).write(to: catalogs.appending(path: "Localizable.xcstrings"))
        let main = """
        import ExtensionFoundation
        import RxCodeExtensionSDK
        @main struct Fixture: AppExtension {
            var configuration: some AppExtensionConfiguration {
                ExtensionService.configuration(scenes: [], test: fixtureReply)
            }
        }
        """
        try Data(main.utf8).write(to: sources.appending(path: "Fixture.swift"))
        try Data("func fixtureReply(_ input: String) -> String { input }".utf8)
            .write(to: sources.appending(path: "Reply.swift"))
        let bundle = root.appending(path: "Contributor.app")
        try ExtensionPackageBuilder.build(directory: source, output: bundle, signer: "-")
        let archive = root.appending(path: "initial.zip")
        let metadata = try ExtensionPackageBuilder.package(bundle: bundle, archive: archive)
        let key = Curve25519.Signing.PrivateKey()
        let trusted = ["fixture": key.publicKey.rawRepresentation]
        let initial = try ExtensionReleaseEnvelope(keyId: "fixture", id: metadata.id, version: metadata.version,
                                                  pluginApi: metadata.pluginApi, sha256: metadata.sha256, cdhashes: metadata.cdhashes)
            .signed(using: key)
        func stage(_ file: URL, _ envelope: ExtensionReleaseEnvelope, requiresDeveloperID: Bool = false) throws -> URL {
            try ExtensionArchive.stage(file, in: root.appending(path: UUID().uuidString), envelope: envelope,
                                       keys: trusted, revocations: nil, requiresDeveloperID: requiresDeveloperID)
        }
        let installed = try stage(archive, initial)
        #expect(throws: ExtensionBuildError.self) { try stage(archive, initial, requiresDeveloperID: true) }
        let resource = "Contents/Resources/RxCodeExtension.json"
        #expect(try String(contentsOf: installed.appending(path: resource), encoding: .utf8) == manifest)
        let sceneResources = installed.appending(path: "Contents/Extensions/Service.appex/Contents/Resources")
        for (file, key, expected) in [("fr.lproj/Localizable.strings", "Account", "Compte"),
                                      ("zh-Hans.lproj/RxCodeExtensionSDK.strings", "Account", "账户")] {
            let data = try Data(contentsOf: sceneResources.appending(path: file))
            let table = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            #expect(table?[key] == expected)
        }

        // Even a valid signature over an incorrect per-architecture claim must fail.
        for hash in try initial.architectureHashes().values {
            var swapped = initial
            swapped.cdhashes = swapped.cdhashes.replacingOccurrences(of: hash, with: String(repeating: "0", count: 40))
            let signed = try swapped.signed(using: key)
            #expect(throws: ExtensionVerificationError.codeHashMismatch) { try stage(archive, signed) }
        }

        // Assemble independently signed archives to exercise checks that follow distribution verification.
        func archiveModifiedBundle() throws -> (URL, ExtensionReleaseEnvelope) {
            let url = root.appending(path: UUID().uuidString + ".zip")
            try ExtensionCompiler.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", bundle.path, url.path])
            var envelope = initial
            envelope.sha256 = try ExtensionReleaseVerifier.archiveDigest(at: url)
            return (url, try envelope.signed(using: key))
        }
        let appex = bundle.appending(path: "Contents/Extensions/Service.appex")
        let embeddedManifest = appex.appending(path: resource)
        try Data((manifest + "\n").utf8).write(to: embeddedManifest)
        let inconsistent = try archiveModifiedBundle()
        #expect(throws: ExtensionBuildError.self) { try stage(inconsistent.0, inconsistent.1) }
        try Data(manifest.utf8).write(to: embeddedManifest)

        let entitlements = root.appending(path: "entitlements.plist")
        let extras = ["com.apple.security.app-sandbox": true, "com.apple.security.network.client": true]
        try PropertyListSerialization.data(fromPropertyList: extras, format: .xml, options: 0).write(to: entitlements)
        try ExtensionCompiler.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime",
                                                       "--entitlements", entitlements.path, appex.path])
        try ExtensionCompiler.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", bundle.path])
        let elevated = try archiveModifiedBundle()
        do {
            _ = try stage(elevated.0, elevated.1)
            Issue.record("The archive with excess entitlements was accepted")
        } catch let error as ExtensionBuildError {
            #expect(error.localizedDescription.contains("app-sandbox"))
        }
    }
}
#endif
