import Foundation
import SwiftUI
import RxCodeCore

// MARK: - Notifications

extension Notification.Name {
    public static let chatShortcutsDidChange = Notification.Name("ChatShortcutRegistry.shortcutsDidChange")
}

// MARK: - Chat Shortcut Data

public struct ChatShortcut: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var message: String
    public var isTerminalCommand: Bool

    public init(id: UUID = UUID(), name: String, message: String, isTerminalCommand: Bool = false) {
        self.id = id
        self.name = name
        self.message = message
        self.isTerminalCommand = isTerminalCommand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        message = try container.decode(String.self, forKey: .message)
        isTerminalCommand = try container.decodeIfPresent(Bool.self, forKey: .isTerminalCommand) ?? false
    }
}

// MARK: - Chat Shortcut Registry

@MainActor
public enum ChatShortcutRegistry {
    private static var shortcuts: [ChatShortcut] = loadShortcuts()

    public static var currentShortcuts: [ChatShortcut] {
        shortcuts
    }

    // MARK: - CRUD

    public static func add(_ shortcut: ChatShortcut) {
        shortcuts.append(shortcut)
        save()
    }

    public static func update(id: UUID, with updated: ChatShortcut) {
        guard let idx = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts[idx] = updated
        save()
    }

    public static func remove(id: UUID) {
        shortcuts.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("RxCode")
            .appendingPathComponent("shortcuts.json")
    }

    private static func loadShortcuts() -> [ChatShortcut] {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ChatShortcut].self, from: data)
        else { return [] }
        return decoded
    }

    private static func save() {
        let url = storeURL
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(shortcuts)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save shortcuts: \(error)")
        }
        NotificationCenter.default.post(name: .chatShortcutsDidChange, object: nil)
    }

    // MARK: - Export / Import

    public static func exportShortcuts() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let content: [ChatShortcut]
        if shortcuts.isEmpty {
            content = [ChatShortcut(
                id: UUID(),
                name: "Example Shortcut",
                message: "This text will be sent to Claude",
                isTerminalCommand: false
            )]
        } else {
            content = shortcuts
        }
        guard let data = try? encoder.encode(content),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return Data((exportCommentHeader() + json + "\n").utf8)
    }

    public static func importShortcuts(from data: Data) -> Bool {
        let jsonData = data.removingJSONComments()
        guard let imported = try? JSONDecoder().decode([ChatShortcut].self, from: jsonData) else {
            return false
        }
        shortcuts = imported
        save()
        return true
    }

    private static func exportCommentHeader() -> String {
        let commentLines = [
            String(localized: "RxCode shortcut export file.", bundle: .module),
            String(localized: "Usage:", bundle: .module),
            String(localized: "Edit the array below to add, remove, or change shortcuts.", bundle: .module),
            String(localized: "Each shortcut supports these properties:", bundle: .module),
            String(localized: "id: optional unique identifier (UUID). Auto-generated on import if omitted.", bundle: .module),
            String(localized: "name: label shown on the shortcut button.", bundle: .module),
            String(localized: "message: text sent to Claude, or command run in the terminal.", bundle: .module),
            String(localized: "isTerminalCommand: true runs the message as a terminal command instead of sending it to chat.", bundle: .module),
            "",
            String(localized: "All properties example:", bundle: .module),
            "{",
            "  \"id\": \"00000000-0000-0000-0000-000000000001\",",
            "  \"isTerminalCommand\": false,",
            "  \"message\": \"\(String(localized: "Message sent to Claude or command run in terminal", bundle: .module))\",",
            "  \"name\": \"\(String(localized: "Shortcut button label", bundle: .module))\"",
            "}",
            "",
        ]
        return commentLines.map { line in
            line.isEmpty ? "//" : "// \(line)"
        }.joined(separator: "\n") + "\n"
    }
}
