import Foundation
import Testing
@testable import RxCodeCore

struct ProjectPromptTests {
    @Test func decodesProjectWithoutPrompt() throws {
        let project = Project(name: "Legacy", path: "/tmp/legacy")
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)
        #expect(decoded.customPrompt == nil)
    }

    @Test func roundTripsProjectPrompt() throws {
        var project = Project(name: "Example", path: "/tmp/example")
        project.customPrompt = "Use SwiftUI."
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: encoded)
        #expect(decoded.customPrompt == "Use SwiftUI.")
    }
}
