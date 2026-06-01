import Foundation
import SwiftUI

/// A single menu command supplied by a hook for a host-owned context menu.
///
/// Context menus are built synchronously by SwiftUI, so hook menu items carry a
/// ready-to-run main-actor action instead of an async outcome. The host still
/// owns where the item is rendered and when standard menu sections are divided.
@MainActor
public struct HookMenuItem: Identifiable {
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    public let role: ButtonRole?
    public let action: @MainActor () -> Void

    public init(
        id: String,
        title: LocalizedStringResource,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }
}
