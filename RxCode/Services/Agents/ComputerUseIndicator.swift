import AppKit

@MainActor
final class ComputerUseIndicator: NSObject {
    static let shared = ComputerUseIndicator()
    private var item: NSStatusItem?
    private var stopActions: [String: () -> Void] = [:]
    private var names: [String: [String]] = [:]

    func update(workspace: String, activeAgents: [String], onStop: @escaping () -> Void) {
        names[workspace] = activeAgents.isEmpty ? nil : activeAgents
        stopActions[workspace] = activeAgents.isEmpty ? nil : onStop
        guard !names.isEmpty else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let status = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = status
        status.button?.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "Agent using this Mac")
        let menu = NSMenu()
        for name in names.values.flatMap({ $0 }).sorted() { menu.addItem(withTitle: name, action: nil, keyEquivalent: "") }
        let stop = menu.addItem(withTitle: "Stop Computer Use", action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        status.menu = menu
    }

    @objc private func stopAll() { for action in stopActions.values { action() } }
}
