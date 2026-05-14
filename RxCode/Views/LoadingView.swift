import SwiftUI
import AppKit
import RxCodeCore

/// Splash shown while `AppState.initialize()` is loading projects, sessions,
/// and warming services. Replaced by the main view as soon as
/// `AppState.isInitialized` flips.
struct LoadingView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkle")
                .font(.system(size: ClaudeTheme.size(56), weight: .light))
                .foregroundStyle(ClaudeTheme.accent)
                .scaleEffect(pulse ? 1.08 : 0.94)
                .opacity(pulse ? 1.0 : 0.7)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

            Text("RxCode")
                .font(.system(size: ClaudeTheme.size(28), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)

            ProgressView()
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClaudeTheme.background.ignoresSafeArea())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(TitleBarHider())
        .onAppear { pulse = true }
    }
}

/// Hides the hosting NSWindow's title bar while the loading view is visible,
/// then restores the original chrome when it disappears.
private struct TitleBarHider: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        var savedStyleMask: NSWindow.StyleMask?
        var savedTitleVisibility: NSWindow.TitleVisibility?
        var savedTitlebarAppearsTransparent: Bool?
        var savedStandardButtonHidden: [NSWindow.ButtonType: Bool] = [:]

        func apply(to window: NSWindow) {
            guard self.window !== window else { return }
            restore()
            self.window = window
            savedStyleMask = window.styleMask
            savedTitleVisibility = window.titleVisibility
            savedTitlebarAppearsTransparent = window.titlebarAppearsTransparent
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                savedStandardButtonHidden[type] = window.standardWindowButton(type)?.isHidden ?? false
            }

            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.isHidden = true
            }
        }

        func restore() {
            guard let window else { return }
            if let mask = savedStyleMask { window.styleMask = mask }
            if let vis = savedTitleVisibility { window.titleVisibility = vis }
            if let transparent = savedTitlebarAppearsTransparent { window.titlebarAppearsTransparent = transparent }
            for (type, hidden) in savedStandardButtonHidden {
                window.standardWindowButton(type)?.isHidden = hidden
            }
            self.window = nil
            savedStyleMask = nil
            savedTitleVisibility = nil
            savedTitlebarAppearsTransparent = nil
            savedStandardButtonHidden.removeAll()
        }

        deinit { restore() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.apply(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.apply(to: window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }
}
