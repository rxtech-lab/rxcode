#if os(macOS)
import SwiftUI
import RxCodeEditor

/// A Swift code editor with live syntax highlighting, used by the custom menu
/// editor for a `swiftScript` show condition. Mirrors `JSONCodeEditor` but for
/// Swift and with the condition `Context` fields as autocomplete placeholders.
struct SwiftConditionEditor: View {
    @Binding var text: String
    var fontSize: CGFloat = 12
    var minHeight: CGFloat = 200

    private let placeholderProvider = PredefinedAutocompleteProvider.placeholders([
        "projectName",
        "projectPath",
        "gitHubRepo",
        "branch",
        "sessionId",
    ])

    var body: some View {
        CodeEditorView(
            text: $text,
            language: "swift",
            fontSize: fontSize,
            autocompleteProvider: placeholderProvider
        )
        .frame(minHeight: minHeight)
    }
}
#endif
