import Observation
import SwiftUI

// MARK: - Theme Colors Definition

public struct ThemeColors: @unchecked Sendable {
    public let textOnAccent: Color
    public let accent: Color
    public let accentText: Color
    public let accentSubtle: Color
    public let background: Color
    public let surfacePrimary: Color
    public let surfaceSecondary: Color
    public let surfaceTertiary: Color
    public let surfaceElevated: Color
    public let sidebarBackground: Color
    public let sidebarItemHover: Color
    public let sidebarItemSelected: Color
    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let border: Color
    public let borderSubtle: Color
    public let codeBackground: Color
    public let codeHeaderBackground: Color
    public let userBubble: Color
    public let userBubbleText: Color
    public let assistantBubble: Color
    public let statusSuccess: Color
    public let statusError: Color
    public let statusWarning: Color
    public let inputBackground: Color
    public let inputBorder: Color

    public init(
        accent: Color, accentSubtle: Color,
        background: Color, surfacePrimary: Color, surfaceSecondary: Color,
        surfaceTertiary: Color, surfaceElevated: Color,
        sidebarBackground: Color, sidebarItemHover: Color, sidebarItemSelected: Color,
        textPrimary: Color, textSecondary: Color, textTertiary: Color,
        border: Color, borderSubtle: Color,
        codeBackground: Color, codeHeaderBackground: Color,
        userBubble: Color, userBubbleText: Color, assistantBubble: Color,
        statusSuccess: Color, statusError: Color, statusWarning: Color,
        inputBackground: Color, inputBorder: Color, textOnAccent: Color = .white
    ) {
        self.textOnAccent = Color(ThemeTextColor(preferred: textOnAccent, alternate: sidebarBackground, background: accent))
        self.accent = accent
        self.accentText = Color(ThemeTextColor(preferred: accent, standardBackground: Color(light: surfaceTertiary, dark: surfacePrimary)))
        self.accentSubtle = accentSubtle
        self.background = background
        self.surfacePrimary = surfacePrimary
        self.surfaceSecondary = surfaceSecondary
        self.surfaceTertiary = surfaceTertiary
        self.surfaceElevated = surfaceElevated
        self.sidebarBackground = sidebarBackground
        self.sidebarItemHover = sidebarItemHover
        self.sidebarItemSelected = sidebarItemSelected
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.border = border
        self.borderSubtle = borderSubtle
        self.codeBackground = codeBackground
        self.codeHeaderBackground = codeHeaderBackground
        self.userBubble = userBubble
        self.userBubbleText = userBubbleText
        self.assistantBubble = assistantBubble
        self.statusSuccess = statusSuccess
        self.statusError = statusError
        self.statusWarning = statusWarning
        self.inputBackground = inputBackground
        self.inputBorder = inputBorder
    }

    // Computed shorthands
    public var inputPlaceholder: Color { textTertiary }
    public var statusRunning: Color { accent }

    /// Keeps the palette's text color unless a native selection needs a different ink.
    public func foreground(_ color: Color) -> Color {
        Color(ThemeTextColor(preferred: color, alternate: textOnAccent))
    }

    /// Retains the ink's hue when a particular surface requires more contrast.
    public func semanticForeground(_ color: Color, on background: Color? = nil) -> Color {
        Color(ThemeTextColor(preferred: color, background: background))
    }

    public func foreground(on fill: Color) -> Color {
        Color(ThemeTextColor(preferred: textOnAccent, alternate: textPrimary, background: fill))
    }
}

// MARK: - Claude Theme (warm terracotta)

extension ThemeColors {
    public static let claude: ThemeColors = {
        let accent = Color.hex(0xD97757)
        let subtle = Color(light: accent.opacity(0.12), dark: accent.opacity(0.15))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         subtle,
            background:           Color(light: .hex(0xF5F4EF), dark: .hex(0x21211E)),
            surfacePrimary:       Color(light: .hex(0xEDEAE0), dark: .hex(0x2A2A27)),
            surfaceSecondary:     Color(light: .hex(0xE5E2D9), dark: .hex(0x353530)),
            surfaceTertiary:      Color(light: .hex(0xDDDAD2), dark: .hex(0x42423D)),
            surfaceElevated:      Color(light: .hex(0xFAF9F6), dark: .hex(0x2F2F2B)),
            sidebarBackground:    Color(light: .hex(0xEDEAE2), dark: .hex(0x1C1C1A)),
            sidebarItemHover:     Color(light: .hex(0xE0DDD4), dark: .hex(0x2A2A27)),
            sidebarItemSelected:  subtle,
            textPrimary:          Color(light: .hex(0x3C3929), dark: .hex(0xD9D7D0)),
            textSecondary:        Color(light: .hex(0x4B4945), dark: .hex(0xC3C2BC)),
            textTertiary:         Color(light: .hex(0x595651), dark: .hex(0xB0B0AA)),
            border:               Color(light: .hex(0xD5D2C8), dark: .hex(0x3B3B36)),
            borderSubtle:         Color(light: .hex(0xE0DDD4), dark: .hex(0x2F2F2B)),
            codeBackground:       Color(light: .hex(0xE8E5DC), dark: .hex(0x1A1A18)),
            codeHeaderBackground: Color(light: .hex(0xDDD9CF), dark: .hex(0x252523)),
            userBubble:           Color(light: .hex(0x3C3929), dark: .hex(0x42423D)),
            userBubbleText:       Color(light: .hex(0xF5F4EF), dark: .hex(0xE8E5DC)),
            assistantBubble:      Color(light: .hex(0xE8E5DC), dark: .hex(0x2A2A27)),
            statusSuccess:        Color(light: .hex(0x375B43), dark: .hex(0x9DC3AA)),
            statusError:          Color(light: .hex(0x823F35), dark: .hex(0xDDB0A6)),
            statusWarning:        Color(light: .hex(0x6F4C21), dark: .hex(0xDEB36D)),
            inputBackground:      Color(light: .hex(0xFAF9F6), dark: .hex(0x2A2A27)),
            inputBorder:          Color(light: .hex(0xD5D2C8), dark: .hex(0x3B3B36))
        )
    }()
}

extension ThemeColors {
    public static let ocean: ThemeColors = {
        let accent: Color = Color(light: .hex(0x1E587B), dark: .hex(0x6CB9DC))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x1E587B).opacity(0.12), dark: .hex(0x6CB9DC).opacity(0.15)),
            background:           Color(light: .hex(0xF0F4F8), dark: .hex(0x111C27)),
            surfacePrimary:       Color(light: .hex(0xE7EEF5), dark: .hex(0x182433)),
            surfaceSecondary:     Color(light: .hex(0xDBE5EF), dark: .hex(0x1F2F41)),
            surfaceTertiary:      Color(light: .hex(0xCEDCE9), dark: .hex(0x273B50)),
            surfaceElevated:      Color(light: .hex(0xF6F9FC), dark: .hex(0x1A2D3E)),
            sidebarBackground:    Color(light: .hex(0xE3ECF4), dark: .hex(0x0D1820)),
            sidebarItemHover:     Color(light: .hex(0xD5E2EE), dark: .hex(0x182433)),
            sidebarItemSelected:  Color(light: .hex(0x1E587B).opacity(0.12), dark: .hex(0x6CB9DC).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x192B3C), dark: .hex(0xC5D5E5)),
            textSecondary:        Color(light: .hex(0x374C62), dark: .hex(0xA3B9CC)),
            textTertiary:         Color(light: .hex(0x425A6E), dark: .hex(0x8FA7BF)),
            border:               Color(light: .hex(0xC4D4E2), dark: .hex(0x2A3D52)),
            borderSubtle:         Color(light: .hex(0xD5E2EE), dark: .hex(0x1F2F41)),
            codeBackground:       Color(light: .hex(0xE0EBF3), dark: .hex(0x0C1722)),
            codeHeaderBackground: Color(light: .hex(0xD2E4EF), dark: .hex(0x132030)),
            userBubble:           Color(light: .hex(0x192B3C), dark: .hex(0x273B50)),
            userBubbleText:       Color(light: .hex(0xF0F4F8), dark: .hex(0xC5D5E5)),
            assistantBubble:      Color(light: .hex(0xE0EBF3), dark: .hex(0x182433)),
            statusSuccess:        Color(light: .hex(0x285D41), dark: .hex(0x87BB9F)),
            statusError:          Color(light: .hex(0x8C3632), dark: .hex(0xD8A19B)),
            statusWarning:        Color(light: .hex(0x6E4D1D), dark: .hex(0xD7A559)),
            inputBackground:      Color(light: .hex(0xF6F9FC), dark: .hex(0x182433)),
            inputBorder:          Color(light: .hex(0xC4D4E2), dark: .hex(0x2A3D52))
        )
    }()
}

extension ThemeColors {
    public static let forest: ThemeColors = {
        let accent: Color = Color(light: .hex(0x235D3F), dark: .hex(0x6CBE8D))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x235D3F).opacity(0.12), dark: .hex(0x6CBE8D).opacity(0.15)),
            background:           Color(light: .hex(0xF0F5F1), dark: .hex(0x0F1E16)),
            surfacePrimary:       Color(light: .hex(0xE6EEE8), dark: .hex(0x162518)),
            surfaceSecondary:     Color(light: .hex(0xDAE5DC), dark: .hex(0x1E3022)),
            surfaceTertiary:      Color(light: .hex(0xCEDDD1), dark: .hex(0x253D2A)),
            surfaceElevated:      Color(light: .hex(0xF7FAF8), dark: .hex(0x1A2F1E)),
            sidebarBackground:    Color(light: .hex(0xE3EDE5), dark: .hex(0x0C1912)),
            sidebarItemHover:     Color(light: .hex(0xD6E5D9), dark: .hex(0x162518)),
            sidebarItemSelected:  Color(light: .hex(0x235D3F).opacity(0.12), dark: .hex(0x6CBE8D).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x1A3328), dark: .hex(0xB8D4C2)),
            textSecondary:        Color(light: .hex(0x345040), dark: .hex(0x98BCA4)),
            textTertiary:         Color(light: .hex(0x455C4E), dark: .hex(0x88AA96)),
            border:               Color(light: .hex(0xC0D4C6), dark: .hex(0x2A3D30)),
            borderSubtle:         Color(light: .hex(0xD6E5D9), dark: .hex(0x1E3022)),
            codeBackground:       Color(light: .hex(0xDCE9DF), dark: .hex(0x0A160D)),
            codeHeaderBackground: Color(light: .hex(0xCEDDD1), dark: .hex(0x102015)),
            userBubble:           Color(light: .hex(0x1A3328), dark: .hex(0x253D2A)),
            userBubbleText:       Color(light: .hex(0xF0F5F1), dark: .hex(0xB8D4C2)),
            assistantBubble:      Color(light: .hex(0xDCE9DF), dark: .hex(0x162518)),
            statusSuccess:        Color(light: .hex(0x235D3F), dark: .hex(0x6CBE8D)),
            statusError:          Color(light: .hex(0x833E36), dark: .hex(0xD79E92)),
            statusWarning:        Color(light: .hex(0x704B22), dark: .hex(0xD9A757)),
            inputBackground:      Color(light: .hex(0xF7FAF8), dark: .hex(0x162518)),
            inputBorder:          Color(light: .hex(0xC0D4C6), dark: .hex(0x2A3D30))
        )
    }()
}

extension ThemeColors {
    public static let lavender: ThemeColors = {
        let accent: Color = Color(light: .hex(0x5E4580), dark: .hex(0xAF9AD2))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x5E4580).opacity(0.12), dark: .hex(0xAF9AD2).opacity(0.15)),
            background:           Color(light: .hex(0xF4F2F8), dark: .hex(0x16111E)),
            surfacePrimary:       Color(light: .hex(0xEBE8F5), dark: .hex(0x1E1828)),
            surfaceSecondary:     Color(light: .hex(0xE0DBF0), dark: .hex(0x271F33)),
            surfaceTertiary:      Color(light: .hex(0xD4CEEA), dark: .hex(0x31273F)),
            surfaceElevated:      Color(light: .hex(0xF9F8FC), dark: .hex(0x211B2E)),
            sidebarBackground:    Color(light: .hex(0xE8E5F3), dark: .hex(0x110E18)),
            sidebarItemHover:     Color(light: .hex(0xDDD9EE), dark: .hex(0x1E1828)),
            sidebarItemSelected:  Color(light: .hex(0x5E4580).opacity(0.12), dark: .hex(0xAF9AD2).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x2C2040), dark: .hex(0xC8BDE0)),
            textSecondary:        Color(light: .hex(0x4E416C), dark: .hex(0xAA9FC7)),
            textTertiary:         Color(light: .hex(0x5C4D7B), dark: .hex(0x9B8CBC)),
            border:               Color(light: .hex(0xC8C0E0), dark: .hex(0x352A48)),
            borderSubtle:         Color(light: .hex(0xDDD9EE), dark: .hex(0x271F33)),
            codeBackground:       Color(light: .hex(0xE2DDEF), dark: .hex(0x100C18)),
            codeHeaderBackground: Color(light: .hex(0xD6D0EA), dark: .hex(0x171121)),
            userBubble:           Color(light: .hex(0x2C2040), dark: .hex(0x31273F)),
            userBubbleText:       Color(light: .hex(0xF4F2F8), dark: .hex(0xC8BDE0)),
            assistantBubble:      Color(light: .hex(0xE2DDEF), dark: .hex(0x1E1828)),
            statusSuccess:        Color(light: .hex(0x315946), dark: .hex(0x70B08D)),
            statusError:          Color(light: .hex(0x803C34), dark: .hex(0xD39385)),
            statusWarning:        Color(light: .hex(0x6C4A21), dark: .hex(0xD9A757)),
            inputBackground:      Color(light: .hex(0xF9F8FC), dark: .hex(0x1E1828)),
            inputBorder:          Color(light: .hex(0xC8C0E0), dark: .hex(0x352A48))
        )
    }()
}

extension ThemeColors {
    public static let amber: ThemeColors = {
        let accent: Color = Color(light: .hex(0x6A4C09), dark: .hex(0xE0AC30))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x6A4C09).opacity(0.12), dark: .hex(0xE0AC30).opacity(0.15)),
            background:           Color(light: .hex(0xF8F5EC), dark: .hex(0x1C1800)),
            surfacePrimary:       Color(light: .hex(0xF0EAD8), dark: .hex(0x261E04)),
            surfaceSecondary:     Color(light: .hex(0xE6E0C8), dark: .hex(0x30280A)),
            surfaceTertiary:      Color(light: .hex(0xDAD4B8), dark: .hex(0x3C3310)),
            surfaceElevated:      Color(light: .hex(0xFCFAF4), dark: .hex(0x2A2208)),
            sidebarBackground:    Color(light: .hex(0xEDE7D2), dark: .hex(0x151200)),
            sidebarItemHover:     Color(light: .hex(0xE2DBC6), dark: .hex(0x261E04)),
            sidebarItemSelected:  Color(light: .hex(0x6A4C09).opacity(0.12), dark: .hex(0xE0AC30).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x3A2C06), dark: .hex(0xD4C47A)),
            textSecondary:        Color(light: .hex(0x59451E), dark: .hex(0xC3AD69)),
            textTertiary:         Color(light: .hex(0x61532F), dark: .hex(0xB59B4A)),
            border:               Color(light: .hex(0xD4CBA0), dark: .hex(0x3A2E10)),
            borderSubtle:         Color(light: .hex(0xE2DBC6), dark: .hex(0x30280A)),
            codeBackground:       Color(light: .hex(0xEAE3CC), dark: .hex(0x110E00)),
            codeHeaderBackground: Color(light: .hex(0xDED7C0), dark: .hex(0x1C1800)),
            userBubble:           Color(light: .hex(0x3A2C06), dark: .hex(0x3C3310)),
            userBubbleText:       Color(light: .hex(0xF8F5EC), dark: .hex(0xD4C47A)),
            assistantBubble:      Color(light: .hex(0xEAE3CC), dark: .hex(0x261E04)),
            statusSuccess:        Color(light: .hex(0x31593E), dark: .hex(0x7AB589)),
            statusError:          Color(light: .hex(0x803D34), dark: .hex(0xD59B8F)),
            statusWarning:        Color(light: .hex(0x6A4C09), dark: .hex(0xE0AC30)),
            inputBackground:      Color(light: .hex(0xFCFAF4), dark: .hex(0x261E04)),
            inputBorder:          Color(light: .hex(0xD4CBA0), dark: .hex(0x3A2E10))
        )
    }()
}

extension ThemeColors {
    public static let midnight: ThemeColors = {
        let accent: Color = Color(light: .hex(0x3545AA), dark: .hex(0x8D9EDF))
        return ThemeColors(
            accent:               accent,
            accentSubtle:         Color(light: .hex(0x3545AA).opacity(0.12), dark: .hex(0x8D9EDF).opacity(0.15)),
            background:           Color(light: .hex(0xF0F1F8), dark: .hex(0x0E0F1C)),
            surfacePrimary:       Color(light: .hex(0xE7E9F5), dark: .hex(0x151827)),
            surfaceSecondary:     Color(light: .hex(0xDCDFF0), dark: .hex(0x1C2033)),
            surfaceTertiary:      Color(light: .hex(0xD0D4EA), dark: .hex(0x232740)),
            surfaceElevated:      Color(light: .hex(0xF6F7FB), dark: .hex(0x191C30)),
            sidebarBackground:    Color(light: .hex(0xE3E5F2), dark: .hex(0x0A0B16)),
            sidebarItemHover:     Color(light: .hex(0xD8DBEE), dark: .hex(0x151827)),
            sidebarItemSelected:  Color(light: .hex(0x3545AA).opacity(0.12), dark: .hex(0x8D9EDF).opacity(0.15)),
            textPrimary:          Color(light: .hex(0x1A1E40), dark: .hex(0xBBC4E8)),
            textSecondary:        Color(light: .hex(0x3F446C), dark: .hex(0x99A0C4)),
            textTertiary:         Color(light: .hex(0x4B517B), dark: .hex(0x888EBA)),
            border:               Color(light: .hex(0xC0C6E0), dark: .hex(0x272D48)),
            borderSubtle:         Color(light: .hex(0xD8DBEE), dark: .hex(0x1C2033)),
            codeBackground:       Color(light: .hex(0xDBDEF0), dark: .hex(0x09091A)),
            codeHeaderBackground: Color(light: .hex(0xCDD1EC), dark: .hex(0x0F1024)),
            userBubble:           Color(light: .hex(0x1A1E40), dark: .hex(0x232740)),
            userBubbleText:       Color(light: .hex(0xF0F1F8), dark: .hex(0xBBC4E8)),
            assistantBubble:      Color(light: .hex(0xDBDEF0), dark: .hex(0x151827)),
            statusSuccess:        Color(light: .hex(0x275A3E), dark: .hex(0x60B07F)),
            statusError:          Color(light: .hex(0x7F3C34), dark: .hex(0xD18F82)),
            statusWarning:        Color(light: .hex(0x6C4920), dark: .hex(0xD9A757)),
            inputBackground:      Color(light: .hex(0xF6F7FB), dark: .hex(0x151827)),
            inputBorder:          Color(light: .hex(0xC0C6E0), dark: .hex(0x272D48))
        )
    }()
}

// MARK: - RxCode Theme (mint, teal, and navy)

// Derived from the app icon: navy #05173D ground, mint #64FFD4 / teal #00E3CC marks,
// pale blue #CDE6FA. Surfaces stay close together so content, not chrome, stands out;
// text is navy (light) or pale blue-white (dark) for high legibility.
extension ThemeColors {
    public static let rxcode: ThemeColors = {
        let accent = Color(light: .hex(0x006156), dark: .hex(0x64F5D2))
        return ThemeColors(
            accent: accent,
            accentSubtle: accent.opacity(0.14),
            background: Color(light: .hex(0xF7F9FC), dark: .hex(0x0A1631)),
            surfacePrimary: Color(light: .hex(0xEEF2F8), dark: .hex(0x111F3D)),
            surfaceSecondary: Color(light: .hex(0xE4EAF3), dark: .hex(0x18284A)),
            surfaceTertiary: Color(light: .hex(0xD9E1EE), dark: .hex(0x213358)),
            surfaceElevated: Color(light: .hex(0xFFFFFF), dark: .hex(0x15244A)),
            sidebarBackground: Color(light: .hex(0xEDF2F8), dark: .hex(0x07112A)),
            sidebarItemHover: Color(light: .hex(0xE1E8F2), dark: .hex(0x18284A)),
            sidebarItemSelected: accent.opacity(0.18),
            textPrimary: Color(light: .hex(0x05173D), dark: .hex(0xEEF4FB)),
            textSecondary: Color(light: .hex(0x33456A), dark: .hex(0xC4D3E6)),
            textTertiary: Color(light: .hex(0x495B7C), dark: .hex(0x9DB0C9)),
            border: Color(light: .hex(0xC6D1E0), dark: .hex(0x2B3E63)),
            borderSubtle: Color(light: .hex(0xDDE4EE), dark: .hex(0x1B2B4D)),
            codeBackground: Color(light: .hex(0xEEF2F8), dark: .hex(0x07112A)),
            codeHeaderBackground: Color(light: .hex(0xE4EAF3), dark: .hex(0x111F3D)),
            userBubble: Color(light: .hex(0x05173D), dark: .hex(0x213358)),
            userBubbleText: .hex(0xEEF4FB),
            assistantBubble: Color(light: .hex(0xEEF2F8), dark: .hex(0x111F3D)),
            statusSuccess: Color(light: .hex(0x006156), dark: .hex(0x64F5D2)),
            statusError: Color(light: .hex(0x963439), dark: .hex(0xFF9C9C)),
            statusWarning: Color(light: .hex(0x774F00), dark: .hex(0xF5CF80)),
            inputBackground: Color(light: .hex(0xFFFFFF), dark: .hex(0x111F3D)),
            inputBorder: Color(light: .hex(0x8090AB), dark: .hex(0x5B7098)),
            textOnAccent: Color(light: .white, dark: .hex(0x05173D))
        )
    }()
}

// MARK: - App Theme Enum

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case rxcode   = "RxCode"
    case claude   = "Terracotta"
    case ocean    = "Ocean"
    case forest   = "Forest"
    case lavender = "Lavender"
    case midnight = "Midnight"
    case amber    = "Amber"

    public var id: String { rawValue }

    public var displayName: LocalizedStringResource {
        switch self {
        case .rxcode:   "RxCode (Default)"
        case .claude:   "Terracotta"
        case .ocean:    "Ocean (Blue)"
        case .forest:   "Forest (Green)"
        case .lavender: "Lavender (Purple)"
        case .midnight: "Midnight (Indigo)"
        case .amber:    "Amber (Yellow)"
        }
    }

    public var displayNameText: String {
        String(localized: displayName)
    }

    public var colors: ThemeColors {
        switch self {
        case .rxcode:   .rxcode
        case .claude:   .claude
        case .ocean:    .ocean
        case .forest:   .forest
        case .lavender: .lavender
        case .midnight: .midnight
        case .amber:    .amber
        }
    }
}

// MARK: - Theme Store

public extension Notification.Name {
    static let rxcodeThemeDidChange = Notification.Name("com.rxcode.themeDidChange")
}

@MainActor
@Observable
public final class ThemeStore {
    public static let shared = ThemeStore()
    private init() {}

    public var current: AppTheme = .rxcode {
        didSet {
            colors = current.colors
            NotificationCenter.default.post(name: .rxcodeThemeDidChange, object: nil)
        }
    }
    public var colors: ThemeColors = .rxcode

    public static let minFontSizeAdjustment: Int = -5
    public static let maxFontSizeAdjustment: Int = 8
    public var fontSizeAdjustment: Int = 0
    public var messageFontSizeAdjustment: Int = 0
}
