import Foundation
import RxCodeEditor
import Testing

@Suite("Predefined autocomplete provider")
struct PredefinedAutocompleteProviderTests {
    @Test("Returns all placeholders at an empty trigger")
    func emptyTriggerReturnsAllPlaceholders() throws {
        let provider = PredefinedAutocompleteProvider.placeholders(["projectName", "branch"])
        let text = #"{"body":"{{"}"#
        let location = (text as NSString).length - 2

        let context = try #require(provider.context(
            in: text,
            selectedRange: NSRange(location: location, length: 0)
        ))

        #expect(context.query.isEmpty)
        #expect(context.replacementRange == NSRange(location: 9, length: 2))
        #expect(provider.completions(for: context).map(\.insertionText) == [
            "{{projectName}}",
            "{{branch}}",
        ])
    }

    @Test("Filters placeholders by typed query")
    func filtersByQuery() throws {
        let provider = PredefinedAutocompleteProvider.placeholders([
            "projectName",
            "projectPath",
            "gitHubRepo",
            "branch",
        ])
        let text = #"{"body":"{{proj"}"#
        let location = (text as NSString).length - 2

        let context = try #require(provider.context(
            in: text,
            selectedRange: NSRange(location: location, length: 0)
        ))

        #expect(context.query == "proj")
        #expect(provider.completions(for: context).map(\.insertionText) == [
            "{{projectName}}",
            "{{projectPath}}",
        ])
    }

    @Test("Does not offer completions after a closed placeholder")
    func ignoresClosedPlaceholder() {
        let provider = PredefinedAutocompleteProvider.placeholders(["projectName"])
        let text = #"{"body":"{{projectName}}"}"#
        let location = (text as NSString).length - 2

        #expect(provider.context(
            in: text,
            selectedRange: NSRange(location: location, length: 0)
        ) == nil)
    }

    @Test("Does not offer completions for whitespace queries")
    func ignoresWhitespaceQuery() {
        let provider = PredefinedAutocompleteProvider.placeholders(["projectName"])
        let text = #"{"body":"{{project name"}"#
        let location = (text as NSString).length - 2

        #expect(provider.context(
            in: text,
            selectedRange: NSRange(location: location, length: 0)
        ) == nil)
    }
}
