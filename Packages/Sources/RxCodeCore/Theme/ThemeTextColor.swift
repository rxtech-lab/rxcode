import SwiftUI

extension EnvironmentValues {
    /// The actual fill drawn by a themed list in an emphasized selection.
    @Entry public var themeSelectionBackground: Color? = nil
}

/// Resolves in the row's environment, where SwiftUI identifies emphasized selections.
struct ThemeTextColor: Hashable, ShapeStyle {
    let preferred: Color
    var alternate: Color?
    var background: Color?
    var standardBackground: Color?

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let foreground = preferred.resolve(in: environment)
        let fill: Color
        if let background {
            fill = background
        } else if let selection = environment.themeSelectionBackground {
            fill = selection
        } else if environment.backgroundProminence == .increased {
            #if os(macOS)
            fill = Color(nsColor: .selectedContentBackgroundColor)
            #else
            fill = .accentColor
            #endif
        } else if let standardBackground {
            fill = standardBackground
        } else {
            return foreground
        }

        let luminance = fill.resolve(in: environment).relativeLuminance
        func contrast(_ color: Color.Resolved) -> Float {
            let ink = color.relativeLuminance * color.opacity + luminance * (1 - color.opacity)
            return (max(ink, luminance) + 0.05) / (min(ink, luminance) + 0.05)
        }
        if contrast(foreground) >= 4.5 { return foreground }
        guard let alternate else { return foreground.adjusted(forBackgroundLuminance: luminance) }
        let alternative = alternate.resolve(in: environment)
        if contrast(alternative) >= 4.5 { return alternative }
        let black = Color.black.resolve(in: environment)
        let white = Color.white.resolve(in: environment)
        return contrast(black) >= contrast(white) ? black : white
    }
}

private extension Color.Resolved {
    var relativeLuminance: Float {
        0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
    }

    /// In linear sRGB, mixing toward black or white changes luminance by the same fraction.
    func adjusted(forBackgroundLuminance background: Float) -> Self {
        let luminance = relativeLuminance
        let darkTarget = (background + 0.05) / 4.52 - 0.05
        let lightTarget = (background + 0.05) * 4.52 - 0.05
        let lighten = darkTarget < 0 || (lightTarget <= 1 && luminance > background)
        let target = lighten ? lightTarget : darkTarget
        let endpoint: Float = lighten ? 1 : 0
        var ink = self
        ink.opacity = 1
        guard endpoint != luminance else { return ink }
        let fraction = max(0, min(1, (target - luminance) / (endpoint - luminance)))
        ink.linearRed += (endpoint - linearRed) * fraction
        ink.linearGreen += (endpoint - linearGreen) * fraction
        ink.linearBlue += (endpoint - linearBlue) * fraction
        return ink
    }
}

extension View {
    /// Accent ink for list rows. Reads the selection fill in a view body, so the ink updates
    /// when the row loses emphasis. Text keeps an environment-resolved color after the environment changes.
    public func themedAccentInk() -> some View {
        modifier(ThemedAccentInk())
    }
}

private struct ThemedAccentInk: ViewModifier {
    @Environment(\.themeSelectionBackground) private var selection

    func body(content: Content) -> some View {
        content.foregroundStyle(selection.map { ClaudeTheme.foreground(on: $0) } ?? ClaudeTheme.foreground(ClaudeTheme.accent))
    }
}
