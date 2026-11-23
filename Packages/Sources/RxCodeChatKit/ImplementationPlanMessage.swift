#if os(macOS)
import SwiftUI

public struct ImplementationPlanMessage: Sendable {
    public let prompt: String
    public let versionNumber: Int
    public let openPlan: @MainActor @Sendable () -> Void

    public init(prompt: String, versionNumber: Int, openPlan: @escaping @MainActor @Sendable () -> Void) {
        self.prompt = prompt
        self.versionNumber = versionNumber
        self.openPlan = openPlan
    }

    /// Provider transcripts may preserve the project's instructions before the original request.
    func matches(_ content: String) -> Bool {
        content == prompt || content.hasSuffix("\n\nUser request:\n" + prompt)
    }
}

public extension EnvironmentValues {
    @Entry var implementationPlanMessage: ImplementationPlanMessage? = nil
}
#endif
