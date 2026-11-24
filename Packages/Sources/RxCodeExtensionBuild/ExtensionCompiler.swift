#if os(macOS)
import Foundation
import Security

public struct ExtensionBuildError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { self.errorDescription = message }
}

public enum ExtensionCompiler {
    public static let architectures = ["arm64", "x86_64"]

    /// Compile only source snapshots in the caller's private staging directory.
    public static func compile(serviceSources: [URL], containerSource: URL, serviceBinary: URL,
                               containerBinary: URL, staging: URL, includeSDK: Bool) throws {
        for architecture in architectures {
            let slice = staging.appending(path: architecture)
            try FileManager.default.createDirectory(at: slice, withIntermediateDirectories: false)
            let target = ["-target", "\(architecture)-apple-macosx26.0"]
            var moduleArguments: [String] = []
            if includeSDK {
                let sdk = try sdkSources()
                try run("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc"] + target + [
                    "-parse-as-library", "-application-extension", "-emit-library", "-static", "-emit-module",
                    "-module-name", "RxCodeExtensionSDK", "-emit-module-path", slice.appending(path: "RxCodeExtensionSDK.swiftmodule").path,
                    "-o", slice.appending(path: "libRxCodeExtensionSDK.a").path
                ] + sdk.map(\.path))
                moduleArguments = ["-I", slice.path, "-L", slice.path, "-lRxCodeExtensionSDK"]
            }
            try run("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc"] + target + [
                "-parse-as-library", "-application-extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"
            ] + moduleArguments + serviceSources.map(\.path) + ["-o", slice.appending(path: "Service").path])
            try run("/usr/bin/xcrun", ["--sdk", "macosx", "clang"] + target + [containerSource.path, "-o", slice.appending(path: "Contributor").path])
        }
        for (name, output) in [("Service", serviceBinary), ("Contributor", containerBinary)] {
            let slices = architectures.map { staging.appending(path: "\($0)/\(name)").path }
            try run("/usr/bin/lipo", ["-create"] + slices + ["-output", output.path])
        }
    }

    static func sdkDirectory() throws -> URL {
        guard let directory = Bundle.module.url(forResource: "RxCodeExtensionSDK", withExtension: nil) else {
            throw ExtensionBuildError("The extension SDK source is missing from the builder.")
        }
        return directory
    }

    public static func sdkSources() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: sdkDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Inspect each slice directly so entitlement and hash checks cover Intel and Apple Silicon.
    public static func codeHashes(of service: URL) throws -> String {
        try architectures.map { architecture in
            var code: SecStaticCode?
            let attributes = [kSecCodeAttributeArchitecture as String: architecture]
            guard SecStaticCodeCreateWithPathAndAttributes(service as CFURL, [], attributes as CFDictionary, &code) == errSecSuccess,
                  let code else { throw ExtensionBuildError("Cannot read the signed \(architecture) extension.") }
            let info = try signingInformation(of: code)
            guard let hash = info[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else {
                throw ExtensionBuildError("The \(architecture) code directory has no CDHash.")
            }
            return architecture + ":" + hash.map { String(format: "%02x", $0) }.joined()
        }.joined(separator: ",")
    }

    /// Apply the same signing requirement to a staged release and to its installed copy.
    public static func verifyContainer(_ container: URL, requiresDeveloperID: Bool) throws {
        var options = ["--verify", "--all-architectures", "--strict", "--deep"]
        if requiresDeveloperID {
            let requirement = #"=anchor apple generic and certificate leaf[subject.OU] = "T7GYB573Y6" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
            options += ["-R", requirement]
            try run("/usr/bin/codesign", options + [container.appending(path: "Contents/Extensions/Service.appex").path])
        }
        try run("/usr/bin/codesign", options + [container.path])
    }

    public static func signingInformation(of code: SecStaticCode) throws -> [String: Any] {
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements.count == 1, let sandbox = entitlements["com.apple.security.app-sandbox"] as? NSNumber,
              CFGetTypeID(sandbox) == CFBooleanGetTypeID(), sandbox.boolValue else {
            throw ExtensionBuildError("The extension must have exactly the app-sandbox entitlement.")
        }
        return info
    }

    @discardableResult public static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw ExtensionBuildError("\(task.executableURL!.lastPathComponent) failed: " + String(decoding: output.suffix(4096), as: UTF8.self))
        }
        return output
    }
}
#endif
