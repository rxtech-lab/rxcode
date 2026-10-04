import XCTest
@testable import RxCode

/// Which tab `TaskFormSheet` opens on when a story or task is created from a
/// board menu, a "+" button, or an edit.
final class TaskCreationModeTests: XCTestCase {

    // MARK: - Editing

    func testExistingRecord_alwaysOpensOnTheForm() {
        for isStory in [true, false] {
            for requested in [TaskCreationMode.ai, .form, nil] {
                XCTAssertEqual(
                    TaskCreationMode.resolved(isExistingRecord: true, isStory: isStory, requested: requested),
                    .form,
                    "A saved record has nothing left to draft, so \(requested as Any) must not open the AI tab"
                )
            }
        }
    }

    // MARK: - Creating without a requested tab

    func testNewStory_defaultsToAI() {
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: true, requested: nil),
            .ai,
            "A story is outlined from a description by default"
        )
    }

    func testNewTask_defaultsToForm() {
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: false, requested: nil),
            .form,
            "A task is written straight into the fields by default"
        )
    }

    // MARK: - Creating with a requested tab

    func testRequestedTabWinsOverTheKindDefault() {
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: false, requested: .ai),
            .ai,
            "\"New Task → With AI\" must open the AI tab"
        )
        XCTAssertEqual(
            TaskCreationMode.resolved(isExistingRecord: false, isStory: true, requested: .form),
            .form,
            "\"New Story → With Form\" must open the form"
        )
    }
}
