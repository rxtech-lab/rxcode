#if os(macOS)
import Foundation

/// Resolves built-in menu item titles in an arbitrary locale.
///
/// The desktop is the only side that builds menus, so titles are localized here.
/// For its own native menus we use the desktop's system locale (`Bundle.main`);
/// when mobile requests a menu it passes its own locale, and we look the title up
/// in that language's `.lproj` bundle so the phone shows translated titles even
/// though the Mac runs a different language.
enum MenuLocalizer {
    /// Localized string for `key` in `locale` (nil => desktop system locale).
    /// `key` is the English source string (the string-catalog key).
    static func string(_ key: String, locale: String?) -> String {
        bundle(for: locale).localizedString(forKey: key, value: key, table: nil)
    }

    /// Localized format string for `key`, filled with `args`. Use for titles with
    /// interpolation, e.g. key `"Code Review for %@"`.
    static func format(_ key: String, locale: String?, _ args: CVarArg...) -> String {
        let fmt = bundle(for: locale).localizedString(forKey: key, value: key, table: nil)
        return String(format: fmt, locale: Locale(identifier: locale ?? Locale.current.identifier), arguments: args)
    }

    /// The `.lproj` bundle for `locale`, falling back to the main bundle (system
    /// locale) when no specific match exists.
    private static func bundle(for locale: String?) -> Bundle {
        guard let locale, !locale.isEmpty else { return .main }
        for code in candidateCodes(locale) {
            if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }

    /// Progressive language candidates, most specific first. Handles `_`/`-`
    /// separators: "zh-Hans-CN" -> ["zh-Hans-CN", "zh-Hans", "zh"].
    private static func candidateCodes(_ locale: String) -> [String] {
        let normalized = locale.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return [normalized] }
        var result: [String] = []
        var current = parts
        while !current.isEmpty {
            result.append(current.joined(separator: "-"))
            current.removeLast()
        }
        return result
    }
}
#endif
