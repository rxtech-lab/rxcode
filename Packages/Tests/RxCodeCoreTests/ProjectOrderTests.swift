import Foundation
import Testing
@testable import RxCodeCore

@Suite("Project order")
struct ProjectOrderTests {

    private func projects(_ names: String...) -> [Project] {
        names.map { Project(name: $0, path: "/tmp/\($0)") }
    }

    @Test("Dragging a project card onto another card takes its slot")
    func reorderOntoTarget() {
        let list = projects("A", "B", "C")

        #expect(list.reordered(moving: list[0].id, onto: list[2].id)?.map(\.name) == ["B", "C", "A"])
        #expect(list.reordered(moving: list[2].id, onto: list[0].id)?.map(\.name) == ["C", "A", "B"])
        #expect(list.reordered(moving: list[1].id, onto: list[0].id)?.map(\.name) == ["B", "A", "C"])
    }

    @Test("A reorder that would change nothing returns nil")
    func reorderNoOp() {
        let list = projects("A", "B")

        #expect(list.reordered(moving: list[0].id, onto: list[0].id) == nil)
        #expect(list.reordered(moving: UUID(), onto: list[0].id) == nil)
        #expect(list.reordered(moving: list[0].id, onto: UUID()) == nil)
        #expect([Project]().reordered(moving: UUID(), onto: UUID()) == nil)
    }
}
