import Foundation

/// What paired phones may do with this Mac's screen. Set on the Mac in
/// Agents → Remote Access; the phone only reads it.
public struct AgentRemoteAccessPolicy: Codable, Sendable, Hashable {
    /// Paired phones may watch the screen live.
    public var allowsViewing: Bool
    /// Paired phones may move the pointer, click, scroll and type.
    public var allowsControl: Bool

    public init(allowsViewing: Bool = false, allowsControl: Bool = false) {
        self.allowsViewing = allowsViewing
        self.allowsControl = allowsControl && allowsViewing
    }

    private enum CodingKeys: String, CodingKey { case allowsViewing, allowsControl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowsViewing = (try? c.decodeIfPresent(Bool.self, forKey: .allowsViewing)) ?? false
        allowsControl = ((try? c.decodeIfPresent(Bool.self, forKey: .allowsControl)) ?? false) && allowsViewing
    }
}

/// Named keys a phone can press on the Mac, mapped to macOS virtual key codes
/// (`kVK_*` from Carbon's Events.h).
public enum RemoteKey {
    public static let codes: [String: UInt16] = [
        "return": 0x24, "enter": 0x4C, "tab": 0x30, "space": 0x31, "delete": 0x33, "forwarddelete": 0x75,
        "escape": 0x35, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
        "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
        "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
        "8": 0x1C, "9": 0x19,
        "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F,
        "/": 0x2C, "\\": 0x2A, "`": 0x32,
    ]

    public static let modifierNames: Set<String> = ["command", "shift", "option", "control", "function"]

    /// Parses a combination such as `cmd+shift+t` into its key code and
    /// modifiers. `nil` for unknown keys or modifiers.
    public static func parse(_ combination: String) -> (code: UInt16, modifiers: Set<String>)? {
        let parts = combination.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last else { return nil }
        // "cmd++" ends with an empty part followed by the literal "+".
        let keyName = last.isEmpty ? "=" : last
        var modifiers: Set<String> = []
        for raw in parts.dropLast() where !raw.isEmpty {
            guard let modifier = normalizedModifier(raw) else { return nil }
            modifiers.insert(modifier)
        }
        guard let code = codes[aliases[keyName] ?? keyName] else { return nil }
        return (code, modifiers)
    }

    public static func normalizedModifier(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "cmd", "command", "meta", "super", "⌘": "command"
        case "shift", "⇧": "shift"
        case "opt", "option", "alt", "⌥": "option"
        case "ctrl", "control", "⌃": "control"
        case "fn", "function": "function"
        default: nil
        }
    }

    static let aliases: [String: String] = [
        "esc": "escape", "backspace": "delete", "del": "forwarddelete", "arrowleft": "left",
        "arrowright": "right", "arrowup": "up", "arrowdown": "down", "spacebar": "space", "ret": "return",
    ]
}
