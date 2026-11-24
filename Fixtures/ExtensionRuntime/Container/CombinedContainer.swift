import AppKit

/// Opening this container publishes the fixture to Launch Services without opening a window.
@main
enum CombinedContainer {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async { app.terminate(nil) }
        app.run()
    }
}
