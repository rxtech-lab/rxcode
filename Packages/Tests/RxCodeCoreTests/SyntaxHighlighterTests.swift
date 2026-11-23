import AppKit
import SwiftUI
import Testing
@testable import RxCodeCore

@Suite("Syntax highlighter")
struct SyntaxHighlighterTests {
    @Test(arguments: AppTheme.allCases, [NSAppearance.Name.aqua, .darkAqua])
    func usesThemeForSwiftUIAndAppKit(theme: AppTheme, appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let colors = theme.colors
        let source = "let item = 42"
        let swiftUI = SyntaxHighlighter.highlight(source, language: "swift", colors: colors)
        let native = SyntaxHighlighter.highlightNS(source, language: "swift", colors: colors)
        let keyword = colors.semanticForeground(colors.accent, on: colors.codeBackground)
        for (text, ink) in [("let", keyword), ("item", colors.textPrimary), ("42", colors.statusWarning)] {
            let range = swiftUI.range(of: text)!
            #expect(swiftUI[range].foregroundColor == ink)
            let offset = (source as NSString).range(of: text).location
            let foreground = try #require(native.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)
            appearance.performAsCurrentDrawingAppearance {
                let expected = NSColor(ink).usingColorSpace(.sRGB)
                #expect(expected != nil && foreground.usingColorSpace(.sRGB) == expected)
            }
        }
    }

    @Test("Handles unterminated strings ending with an escape")
    func handlesUnterminatedStringsEndingWithEscape() {
        let cases = [
            "let single = 'value\\",
            "let double = \"value\\",
            "let triple = \"\"\"value\\",
        ]

        for source in cases {
            #expect(SyntaxHighlighter.highlightNS(source, language: "swift").string == source)
        }
    }
}
