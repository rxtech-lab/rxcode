import Foundation
import RxCodeExtensionBuild

enum BuildCommands {
    static func run(command: String, arguments: [String]) throws {
        guard let path = arguments.first else { throw ExtensionBuildError("Pass an extension source directory or built app.") }
        var options: [String: String] = [:]
        var remaining = arguments.dropFirst()
        while let key = remaining.popFirst() {
            guard ["--output", "--sign"].contains(key), options[key] == nil, let value = remaining.popFirst() else {
                throw ExtensionBuildError("Invalid option: " + key)
            }
            options[key] = value
        }
        let source = URL(fileURLWithPath: path)
        guard let destination = options["--output"] else { throw ExtensionBuildError("Pass an output path with --output.") }
        let output = URL(fileURLWithPath: destination)
        if command == "build" {
            try ExtensionPackageBuilder.build(directory: source, output: output, signer: options["--sign"] ?? "-")
        } else {
            guard options["--sign"] == nil else { throw ExtensionBuildError("Sign the bundle during build.") }
            let metadata = try ExtensionPackageBuilder.package(bundle: source, archive: output)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(metadata), as: UTF8.self))
        }
    }
}
