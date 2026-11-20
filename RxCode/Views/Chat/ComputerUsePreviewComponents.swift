import AppKit
import RxCodeCore
import SwiftUI

/// One previewable window: an app driven by computer use, a browser tab
/// screenshot, or a window the user picked manually.
///
/// Frame and status are read through the source objects so only the leaf views
/// that display them re-render on each captured frame.
struct ComputerUsePreviewItem: Identifiable {
    enum ID: Hashable {
        case window(ComputerUseMonitorWindow.ID)
        case manual
    }

    enum Source {
        case native(ComputerUseLiveWindowStream?, snapshot: CGImage?)
        case snapshot(CGImage?)
        case manual(NativeWindowPreviewCapture)
    }

    let id: ID
    let title: String
    let subtitle: String?
    let bundleID: String?
    let fallbackSymbol: String
    let observedAt: Date
    let source: Source

    init(window: ComputerUseMonitorWindow, stream: ComputerUseLiveWindowStream?) {
        id = .window(window.id)
        title = window.title
        subtitle = window.appName == window.title ? nil : window.appName
        observedAt = window.observedAt
        switch window.id {
        case .native(let appID):
            bundleID = appID
            fallbackSymbol = "macwindow"
            source = .native(stream, snapshot: window.preview)
        case .browser:
            bundleID = nil
            fallbackSymbol = "globe"
            source = .snapshot(window.preview)
        }
    }

    init(manual capture: NativeWindowPreviewCapture, window: NativeWindowPreviewCapture.Window) {
        id = .manual
        title = window.title
        subtitle = window.appName == window.title ? nil : window.appName
        bundleID = window.bundleID
        fallbackSymbol = "macwindow"
        observedAt = .distantPast
        source = .manual(capture)
    }

    var frame: CGImage? {
        switch source {
        case .native(let stream, let snapshot): stream?.frame ?? snapshot
        case .snapshot(let image): image
        case .manual(let capture): capture.frame
        }
    }

    var isLive: Bool {
        switch source {
        case .native(let stream, _): stream?.status == .live
        case .snapshot: false
        case .manual(let capture): capture.frame != nil
        }
    }

    var needsAccess: Bool {
        if case .native(let stream, _) = source { return stream?.status == .needsAccess }
        return false
    }

    var isRunningApp: Bool {
        guard let bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func bringAppToFront() {
        guard let bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }
}

/// The window image, or a status placeholder while the stream is starting.
struct ComputerUsePreviewSurface: View {
    let item: ComputerUsePreviewItem
    let onChooseWindow: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let frame = item.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
                    .padding(12)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            if item.needsAccess {
                Image(systemName: "lock.shield")
                    .font(.system(size: ClaudeTheme.size(20)))
                Text("Allow Screen Recording to watch Codex work live.")
                    .multilineTextAlignment(.center)
                Button("Allow Screen Recording…") { ComputerUseWindowCapture.requestAccess() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Looking for the window…")
                Button("Choose Window…", action: onChooseWindow)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .font(.system(size: ClaudeTheme.size(11)))
        .foregroundStyle(.white.opacity(0.75))
    }
}

/// The app's Finder icon, or an SF Symbol when the app can't be found.
struct ComputerUseAppIcon: View {
    let bundleID: String?
    let fallbackSymbol: String
    var size: CGFloat = 16

    var body: some View {
        if let icon = bundleID.flatMap(ComputerUseAppIconCache.icon(for:)) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        }
    }
}

private enum ComputerUseAppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

struct ComputerUseLiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: ClaudeTheme.size(9), weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}

/// Shows the badge only while `item` streams; isolated so frame updates don't
/// re-render the surrounding layout.
struct ComputerUseLiveIndicator: View {
    let item: ComputerUsePreviewItem

    var body: some View {
        if item.isLive { ComputerUseLiveBadge() }
    }
}
