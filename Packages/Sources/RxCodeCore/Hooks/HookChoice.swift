import Foundation

/// A single selectable option presented to the user by a hook (e.g. one secret
/// environment). Decouples the generic `HookController.requestChoice` picker
/// from any domain model, so the same primitive serves future hooks.
public struct HookChoice: Identifiable, Sendable, Hashable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// A decrypted file a hook intends to write to disk. Carries plaintext, so it
/// never leaves the in-process app boundary.
public struct HookSecretFile: Sendable, Hashable {
    public let filename: String
    public let content: String

    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }
}
