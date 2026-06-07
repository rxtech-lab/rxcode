#if os(macOS)
import SwiftUI
import RxCodeEditor

/// A lightweight JSON editor with live syntax highlighting, used by the custom
/// menu editor for the request body.
struct JSONCodeEditor: View {
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
            language: "json",
            fontSize: fontSize,
            autocompleteProvider: placeholderProvider
        )
        .frame(minHeight: minHeight)
    }
}
#endif
