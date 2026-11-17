import Foundation

/// The same bundled skill is available to regular chat and the Settings creator.
nonisolated enum PetLookSkill {
    static let name = "rxcode-pet-look"

    static func instructions() throws -> String {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/PetLookSkill/SKILL.md")
        guard let url = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "PetLookSkill")
            ?? Bundle.main.url(forResource: "SKILL", withExtension: "md")
            ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
