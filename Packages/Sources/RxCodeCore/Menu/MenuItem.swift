import Foundation
import SwiftUI

// MARK: - Serializable, cross-platform menu

/// A single menu entry that is BOTH a SwiftUI `View` and `Codable`.
///
/// This is the one menu vocabulary shared by desktop and mobile. The desktop
/// builds `[MenuItem]` from hooks and renders them natively (a `MenuItem` is a
/// `View`). Mobile asks the desktop for the same `[MenuItem]`, which crosses the
/// E2E relay as JSON, and renders the *identical* type on-device. Because the
/// item carries a serializable `MenuAction` (never a closure), the same value is
/// safe to encode and ship.
///
/// Tapping a leaf item routes its `action` to the `menuActionHandler` injected
/// through the environment, so each platform decides what a command means:
/// desktop dispatches it locally, mobile sends it back over the relay, and a
/// `.deepLink` opens platform-local UI (a sheet) on whichever side renders it.
public struct MenuItem: View, Codable, Identifiable, Hashable, Sendable {
    /// Whether this row is a tappable item or a visual separator.
    public enum Kind: String, Codable, Sendable {
        case item
        case separator
    }

    public let id: String
    public let kind: Kind
    /// Already-localized, display-ready title. The desktop is the only side that
    /// builds menus, so titles are resolved there (`LocalizedStringResource` is
    /// not cleanly `Codable`) and shipped as plain strings.
    public let title: String
    public let systemImage: String?
    public let role: MenuItemRole?
    public let isDisabled: Bool
    /// What happens on tap. `nil` for separators and for submenu parents.
    public let action: MenuAction?
    /// Non-nil when this item is a submenu; rendered as a nested `Menu`.
    public let children: [MenuItem]?

    public init(
        id: String,
        kind: Kind = .item,
        title: String = "",
        systemImage: String? = nil,
        role: MenuItemRole? = nil,
        isDisabled: Bool = false,
        action: MenuAction? = nil,
        children: [MenuItem]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isDisabled = isDisabled
        self.action = action
        self.children = children
    }

    /// A non-interactive divider between sections.
    public static func separator(id: String) -> MenuItem {
        MenuItem(id: id, kind: .separator)
    }

    // MARK: View

    public var body: some View {
        MenuItemRow(item: self)
    }
}

/// `ButtonRole` isn't `Codable`; mirror just the roles a menu needs.
public enum MenuItemRole: String, Codable, Sendable, Hashable {
    case destructive
}

/// What a tapped menu item does. Either run a named command (the desktop is the
/// source of truth and performs the work) or open a deep link that presents
/// platform-local UI such as a sheet.
public enum MenuAction: Codable, Sendable, Hashable {
    case command(MenuActionCommand)
    case deepLink(URL)
}

/// A serializable description of work to perform. `kind` selects the operation;
/// the optional fields carry its parameters. Kept flat (rather than per-command
/// structs) so one `Codable` type round-trips every command and the dispatcher
/// is a single switch.
public struct MenuActionCommand: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        // Project-scoped — real work the desktop performs.
        case projectCodeReview          // review the project's current branch
        case projectCommitAll           // commit all uncommitted changes
        case projectCreatePullRequest   // push branch + open a PR

        // Thread-scoped.
        case threadCodeReview           // review one thread's changes
        case threadCommitFiles          // commit only this thread's files
    }

    public let kind: Kind
    public let projectId: UUID?
    public let sessionId: String?
    public let branch: String?

    public init(
        kind: Kind,
        projectId: UUID? = nil,
        sessionId: String? = nil,
        branch: String? = nil
    ) {
        self.kind = kind
        self.projectId = projectId
        self.sessionId = sessionId
        self.branch = branch
    }
}

// MARK: - Action handler (environment)

/// Platform-specific sink for menu taps. Injected via `.menuActionHandler(...)`
/// so the very same `MenuItem` view dispatches differently on each side:
/// desktop runs the command locally, mobile relays it, and either opens deep
/// links with its own URL handling.
public struct MenuActionHandler: Sendable {
    public let perform: @MainActor (MenuAction) -> Void

    public init(perform: @escaping @MainActor (MenuAction) -> Void) {
        self.perform = perform
    }

    /// A no-op handler (the environment default).
    public static let none = MenuActionHandler { _ in }
}

private struct MenuActionHandlerKey: EnvironmentKey {
    static let defaultValue = MenuActionHandler.none
}

public extension EnvironmentValues {
    /// The sink that receives a `MenuAction` when a `MenuItem` is tapped.
    var menuActionHandler: MenuActionHandler {
        get { self[MenuActionHandlerKey.self] }
        set { self[MenuActionHandlerKey.self] = newValue }
    }
}

public extension View {
    /// Install the handler that `MenuItem` taps route through.
    func menuActionHandler(_ handler: MenuActionHandler) -> some View {
        environment(\.menuActionHandler, handler)
    }

    /// Convenience: install a handler from a bare closure.
    func menuActionHandler(_ perform: @escaping @MainActor (MenuAction) -> Void) -> some View {
        environment(\.menuActionHandler, MenuActionHandler(perform: perform))
    }
}

// MARK: - Rendering

/// Renders a single `MenuItem`, reading the active `menuActionHandler` from the
/// environment. Kept private so `MenuItem` stays a clean `Codable` value type
/// (no stored `@Environment`); the environment lookup lives here instead.
private struct MenuItemRow: View {
    let item: MenuItem
    @Environment(\.menuActionHandler) private var handler

    var body: some View {
        switch item.kind {
        case .separator:
            Divider()
        case .item:
            if let children = item.children, !children.isEmpty {
                Menu {
                    ForEach(children) { child in child }
                } label: {
                    label
                }
            } else {
                Button(role: buttonRole) {
                    if let action = item.action { handler.perform(action) }
                } label: {
                    label
                }
                .disabled(item.isDisabled)
            }
        }
    }

    private var buttonRole: ButtonRole? {
        item.role == .destructive ? .destructive : nil
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage = item.systemImage {
            Label(item.title, systemImage: systemImage)
        } else {
            Text(item.title)
        }
    }
}

/// Renders a list of `MenuItem`s as menu content (buttons, submenus, and
/// dividers). Drop this inside a `.contextMenu { }` or `Menu { }` builder on
/// either platform.
public struct MenuItemsView: View {
    public let items: [MenuItem]

    public init(_ items: [MenuItem]) {
        self.items = items
    }

    public var body: some View {
        ForEach(items) { item in item }
    }
}
