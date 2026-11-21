import RxCodeCore
import SwiftUI

private struct ChooseWindowPreviewKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var chooseWindowPreview: (() -> Void)? {
        get { self[ChooseWindowPreviewKey.self] }
        set { self[ChooseWindowPreviewKey.self] = newValue }
    }
}

/// Floating live preview of the windows Codex drives with computer use, plus a
/// window the user chose manually. Every window streams concurrently; the
/// panel shows one at a time and the sheet shows them all.
struct ComputerUseMonitorOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var capture = NativeWindowPreviewCapture()
    @State private var streams = ComputerUseLiveStreams()
    @State private var pinnedItemID: ComputerUsePreviewItem.ID?
    @State private var showsAllWindows = false

    let sessionKey: String

    var body: some View {
        let windows = appState.computerUseMonitors(forSession: sessionKey)
        let items = previewItems(for: windows)
        GeometryReader { geometry in
            if !items.isEmpty, !windowState.isComputerUsePreviewMinimized {
                ComputerUsePreviewPanel(
                    items: items,
                    pinnedItemID: $pinnedItemID,
                    availableSize: geometry.size,
                    onChooseWindow: capture.chooseWindow,
                    onShowAll: { showsAllWindows = true },
                    onClose: { close(windows: windows) }
                )
                .onChange(of: windows.compactMap(\.nativeTarget), initial: true) {
                    streams.sync(with: windows)
                }
                .task(id: Set(windows.compactMap(\.nativeTarget?.appID))) {
                    streams.sync(with: windows)
                    await streams.run()
                }
                .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showsAllWindows) {
            ComputerUseWindowsSheet(
                items: items,
                canChooseWindow: capture.window == nil && !capture.isChoosingWindow,
                onChooseWindow: capture.chooseWindow,
                onStopManualPreview: capture.stop,
                onSelect: { pinnedItemID = $0 }
            )
        }
        .focusedSceneValue(\.chooseWindowPreview, chooseWindowAction)
        .onChange(of: sessionKey) {
            windowState.isComputerUsePreviewMinimized = false
            pinnedItemID = nil
        }
        .onChange(of: items.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            // Drop the banner and sheet once there is nothing left to show.
            windowState.isComputerUsePreviewMinimized = false
            showsAllWindows = false
            pinnedItemID = nil
        }
        .onChange(of: capture.window != nil) { _, isCapturing in
            // Show a window the user just picked; fall back to following Codex
            // when that preview stops.
            if isCapturing {
                pinnedItemID = .manual
            } else if pinnedItemID == .manual {
                pinnedItemID = nil
            }
        }
        .onDisappear {
            capture.stop()
            windowState.isComputerUsePreviewMinimized = false
        }
        .alert("Couldn’t Preview Window", isPresented: showsCaptureError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = capture.errorMessage { Text(message) }
        }
    }

    private func previewItems(for windows: [ComputerUseMonitorWindow]) -> [ComputerUsePreviewItem] {
        var items = windows.map { ComputerUsePreviewItem(window: $0, stream: streams.stream(for: $0)) }
        if let window = capture.window {
            items.append(ComputerUsePreviewItem(manual: capture, window: window))
        }
        return items
    }

    /// Closing a computer-use preview collapses it into the banner above the
    /// chat input so it can be expanded again; a manually chosen window
    /// preview with nothing else to show simply stops.
    private func close(windows: [ComputerUseMonitorWindow]) {
        guard !windows.isEmpty else {
            capture.stop()
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            windowState.isComputerUsePreviewMinimized = true
        }
    }

    private var chooseWindowAction: (() -> Void)? {
        guard capture.window == nil, !capture.isChoosingWindow else { return nil }
        return { capture.chooseWindow() }
    }

    private var showsCaptureError: Binding<Bool> {
        Binding(
            get: { capture.errorMessage != nil },
            set: { if !$0 { capture.errorMessage = nil } }
        )
    }
}

/// Picture-in-picture panel: one large live window with a header overlay and
/// a footer to switch windows, open the sheet, or minimize.
private struct ComputerUsePreviewPanel: View {
    @State private var panelHeight: CGFloat = 0
    @State private var position = CGSize.zero
    @GestureState private var translation = CGSize.zero

    let items: [ComputerUsePreviewItem]
    @Binding var pinnedItemID: ComputerUsePreviewItem.ID?
    let availableSize: CGSize
    let onChooseWindow: () -> Void
    let onShowAll: () -> Void
    let onClose: () -> Void

    private static let margin: CGFloat = 10
    private static let coordinateSpace = "computer-use-preview-container"

    private var panelWidth: CGFloat { max(0, min(340, availableSize.width - Self.margin * 2)) }

    private var pinnedItem: ComputerUsePreviewItem? {
        items.first { $0.id == pinnedItemID }
    }

    /// The pinned window, otherwise the one Codex touched most recently.
    private var focusedItem: ComputerUsePreviewItem? {
        pinnedItem ?? items.max { $0.observedAt < $1.observedAt }
    }

    private var offset: CGSize {
        let restingPosition = clamped(position)
        return clamped(CGSize(
            width: restingPosition.width + translation.width,
            height: restingPosition.height + translation.height
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let item = focusedItem {
                ZStack(alignment: .top) {
                    ComputerUsePreviewSurface(item: item, onChooseWindow: onChooseWindow)
                    header(for: item)
                }
                .aspectRatio(16 / 10, contentMode: .fit)
            }
            footer
        }
        .frame(width: panelWidth)
        .background(ClaudeTheme.surfaceElevated)
        .clipShape(.rect(cornerRadius: ClaudeTheme.cornerRadiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                .strokeBorder(ClaudeTheme.borderSubtle)
                .allowsHitTesting(false)
        }
        .shadow(color: ClaudeTheme.shadowColor, radius: 12, y: 4)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { panelHeight = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("computer-use-monitor-stack")
        .offset(offset)
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .coordinateSpace(.named(Self.coordinateSpace))
    }

    private func header(for item: ComputerUsePreviewItem) -> some View {
        HStack(spacing: 7) {
            ComputerUseAppIcon(bundleID: item.bundleID, fallbackSymbol: item.fallbackSymbol, size: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: ClaudeTheme.size(11.5), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pinnedItem == nil ? "Following Codex" : "Pinned")
                    .font(.system(size: ClaudeTheme.size(9.5)))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
            .foregroundStyle(ClaudeTheme.textPrimary)
            Spacer(minLength: 6)
            ComputerUseLiveIndicator(item: item)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .background(
            LinearGradient(stops: [.init(color: .black.opacity(0.9), location: 0),
                                   .init(color: .black.opacity(0.84), location: 0.75),
                                   .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .help(item.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        ComputerUsePreviewChip(item: item, isSelected: item.id == focusedItem?.id) {
                            pinnedItemID = item.id
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)

            if pinnedItemID != nil {
                footerButton("Follow Codex", systemImage: "scope") { pinnedItemID = nil }
            }
            footerButton("Show All Windows", systemImage: "square.grid.2x2", action: onShowAll)
            footerButton("Minimize to the banner above the message box", systemImage: "xmark", action: onClose)
                .accessibilityIdentifier("close-window-preview")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(ClaudeTheme.textSecondary)
        .help(title)
    }

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .named(Self.coordinateSpace))
            .updating($translation) { value, translation, _ in translation = value.translation }
            .onEnded { value in
                let restingPosition = clamped(position)
                position = clamped(CGSize(
                    width: restingPosition.width + value.translation.width,
                    height: restingPosition.height + value.translation.height
                ))
            }
    }

    private func clamped(_ position: CGSize) -> CGSize {
        CGSize(
            width: min(0, max(position.width, panelWidth + Self.margin * 2 - availableSize.width)),
            height: max(0, min(position.height, availableSize.height - panelHeight - Self.margin * 2))
        )
    }
}

/// App icon button for switching the panel to another window.
private struct ComputerUsePreviewChip: View {
    let item: ComputerUsePreviewItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ComputerUseAppIcon(bundleID: item.bundleID, fallbackSymbol: item.fallbackSymbol, size: 18)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? ClaudeTheme.accentSubtle : .clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? ClaudeTheme.accent.opacity(0.6) : .clear)
                }
                .overlay(alignment: .topTrailing) { ComputerUseChipLiveDot(item: item) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ComputerUseChipLiveDot: View {
    let item: ComputerUsePreviewItem

    var body: some View {
        if item.isLive {
            Circle()
                .fill(.red)
                .frame(width: 5, height: 5)
                .offset(x: 1, y: -1)
        }
    }
}

/// Shown above the chat input while the computer-use preview is minimized;
/// tapping it expands the floating preview again.
struct ComputerUsePreviewBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private var title: String {
        let windows = appState.computerUseMonitors(forSession: windowState.currentSessionId ?? windowState.newSessionKey)
        guard !windows.isEmpty else { return String(localized: "Window preview minimized") }
        let names = windows.map { $0.appName ?? $0.title }
        return String(localized: "Computer use — \(ListFormatter.localizedString(byJoining: names))")
    }

    var body: some View {
        if windowState.isComputerUsePreviewMinimized {
            PendingActionBanner(icon: "desktopcomputer", title: title, actionTitle: String(localized: "Show")) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    windowState.isComputerUsePreviewMinimized = false
                }
            }
            .accessibilityIdentifier("computer-use-preview-banner")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
