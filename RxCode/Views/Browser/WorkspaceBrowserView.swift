import RxCodeCore
import SwiftUI
import WebKit

struct WorkspaceBrowserView: View {
    var isFocused = true

    private enum BrowserSheet: String, Identifiable {
        case importCookies, importExtensions, manageExtensions
        var id: String { rawValue }
    }

    @Environment(WorkspaceBrowser.self) private var browser
    @State private var sheet: BrowserSheet?
    @State private var addingExtensionFile = false
    @State private var draggingTabID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(browser.tabs) { tab in
                                BrowserTabLabel(tab: tab, selected: browser.selectedID == tab.id, isFocused: isFocused,
                                                select: { browser.selectedID = tab.id }, close: { browser.close(tab.id) },
                                                duplicate: { browser.duplicate(tab.id) },
                                                closeOthers: browser.tabs.count > 1 ? { browser.closeOthers(than: tab.id) } : nil)
                                    .workspaceReorderableTab(id: tab.id, draggingID: $draggingTabID,
                                                             move: browser.move, onExternalURLs: openDropped)
                                    .id(tab.id)
                            }
                        }
                        .frame(height: 30)
                    }
                    // The empty space after the tabs: double-click for a new tab, drop links to open them.
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { browser.addTab() }
                            .accessibilityHidden(true)
                    }
                    .workspaceTabStripDropArea(draggingID: $draggingTabID,
                                               move: browser.move, onExternalURLs: openDropped)
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .onChange(of: browser.selectedID, initial: true) { _, id in
                        if let id { withAnimation(.smooth(duration: 0.2)) { reader.scrollTo(id) } }
                    }
                    .onChange(of: browser.tabs.map(\.id)) { _, ids in
                        if let draggingTabID, !ids.contains(draggingTabID) { self.draggingTabID = nil }
                    }
                }
                WorkspaceTabStripButton(systemImage: "plus", help: "New tab (⌘T)") { browser.addTab() }
                    .keyboardShortcut(isFocused ? KeyboardShortcut("t", modifiers: .command) : nil)
                    .accessibilityIdentifier("browser-new-tab")
                BrowserExtensionActions { sheet = .manageExtensions }
                Menu {
                    Button("Import Cookies from Chrome…", systemImage: "square.and.arrow.down") { sheet = .importCookies }
                        .disabled(browser.cookieImportStatus == .importing)
                    Divider()
                    Button("Import Extensions from Chrome…", systemImage: "puzzlepiece.extension") { sheet = .importExtensions }
                    Button("Add Extension from File…", systemImage: "doc.badge.plus") { addingExtensionFile = true }
                    Button("Manage Extensions…", systemImage: "slider.horizontal.3") { sheet = .manageExtensions }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Browser options")
                .accessibilityLabel("Browser options")
                .accessibilityIdentifier("browser-options")
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(ClaudeTheme.surfaceSecondary.opacity(0.5))
            Divider()
            if let tab = browser.selectedTab {
                BrowserPageView(tab: tab, isFocused: isFocused)
                    .id(tab.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if browser.cookieImportStatus != nil { CookieImportStatusOverlay() } else { ExtensionStatusOverlay() }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: browser.cookieImportStatus)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: BrowserExtensionManager.shared.status)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .importCookies:
                NavigationStack { ChromeCookieImportSheet() }
                    .frame(minWidth: 420, idealWidth: 480, minHeight: 300, idealHeight: 340)
            case .importExtensions:
                NavigationStack { ChromeExtensionImportSheet() }
                    .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 540)
            case .manageExtensions:
                BrowserExtensionsSheet()
                    .frame(minWidth: 480, idealWidth: 560, minHeight: 400, idealHeight: 520)
            }
        }
        .extensionFileImporter(isPresented: $addingExtensionFile)
        .onAppear {
            browser.restoreSessionIfNeeded()
            if browser.tabs.isEmpty { browser.addTab() }
        }
        .onChange(of: isFocused, initial: true) { _, focused in
            if focused { browser.didFocus() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-browser")
    }

    private func openDropped(_ urls: [URL]) {
        for url in urls where WorkspaceBrowser.isWebURL(url) { browser.addTab(url: url) }
    }
}

private struct BrowserTabLabel: View {
    @ObservedObject var tab: WorkspaceBrowserTab
    let selected: Bool
    let isFocused: Bool
    let select: () -> Void
    let close: () -> Void
    let duplicate: () -> Void
    let closeOthers: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tab.webView.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: tab.address?.scheme == "https" ? "lock.fill" : "globe")
                        .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                        .foregroundStyle(selected ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                }
            }
            .frame(width: 14, height: 14)
            Text(tab.title)
                .font(.system(size: ClaudeTheme.size(12), weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            WorkspaceTabCloseButton(isVisible: selected || isHovered, help: "Close tab", action: close)
                .keyboardShortcut(isFocused && selected ? KeyboardShortcut("w", modifiers: .command) : nil)
                .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(minWidth: 96, maxWidth: 180)
        .frame(height: 28)
        .workspaceTabChip(selected: selected, hovered: isHovered)
        .contentShape(.rect(cornerRadius: 7))
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .help(tab.address?.absoluteString ?? tab.title)
        .contextMenu {
            Button("Duplicate Tab", systemImage: "plus.square.on.square", action: duplicate)
            Button("Reload", systemImage: "arrow.clockwise") { tab.reload() }
                .disabled(tab.address == nil)
            Divider()
            Button("Close Tab", systemImage: "xmark", action: close)
            if let closeOthers {
                Button("Close Other Tabs", action: closeOthers)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Close") { close() }
        .accessibilityIdentifier("browser-tab-\(tab.id)")
    }
}

private struct BrowserPageView: View {
    @ObservedObject var tab: WorkspaceBrowserTab
    let isFocused: Bool
    @State private var address = ""
    @State private var invalidAddress = false
    @State private var designing = false
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!tab.webView.canGoBack)
                    .accessibilityLabel("Back")
                    .help("Back")
                Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!tab.webView.canGoForward)
                    .accessibilityLabel("Forward")
                    .help("Forward")
                HStack(spacing: 7) {
                    Image(systemName: tab.address?.scheme == "https" ? "lock" : "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Enter a web address", text: $address)
                        .textFieldStyle(.plain)
                        .focused($editingAddress)
                        .accessibilityIdentifier("browser-address")
                        .onSubmit(navigate)
                    Button {
                        if tab.webView.isLoading { tab.webView.stopLoading() } else { tab.reload() }
                    } label: { Image(systemName: tab.webView.isLoading ? "xmark" : "arrow.clockwise") }
                    .disabled(tab.address == nil)
                    .keyboardShortcut(isFocused ? KeyboardShortcut("r", modifiers: .command) : nil)
                    .accessibilityLabel(tab.webView.isLoading ? "Stop loading" : "Reload")
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
                Toggle(isOn: $designing) { Label("Design", systemImage: "scope") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(tab.address == nil)
                    .help("Select a page element for refinement")
                    .accessibilityIdentifier("browser-design")
                Button {
                    if let url = tab.address { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "safari") }
                .disabled(tab.address == nil)
                .accessibilityLabel("Open in default browser")
                .help("Open in default browser")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ZStack(alignment: .top) {
                BrowserWebView(webView: tab.webView)
                    .previewSelectionComments(for: designing || tab.webView.isLoading || tab.failure != nil ? nil : tab.address,
                                              browserTabID: tab.id)
                if designing, tab.failure == nil, !tab.webView.isLoading, let address = tab.address {
                    DesignSelectionOverlay(boundsAtPoint: tab.designHoverBounds) { point, size in
                        try await tab.designSelection(at: point, size: size)
                    }
                    .id(address)
                }
                if let failure = tab.failure {
                    ContentUnavailableView {
                        Label("Couldn’t load page", systemImage: "globe")
                    } description: { Text(failure) } actions: {
                        Button("Try Again") { tab.reload() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ClaudeTheme.background)
                } else if tab.address == nil && !tab.webView.isLoading {
                    ContentUnavailableView("New tab", systemImage: "globe",
                                           description: Text("Enter a web address or a local development URL above."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ClaudeTheme.background)
                }
                if tab.webView.isLoading { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
            }
        }
        .background {
            Button("Focus Address", action: focusAddress)
                .keyboardShortcut(isFocused ? KeyboardShortcut("l", modifiers: .command) : nil)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .onAppear {
            address = tab.address?.absoluteString ?? ""
            editingAddress = isFocused && address.isEmpty
        }
        .onChange(of: tab.address) { _, url in
            if !editingAddress { address = url?.absoluteString ?? "" }
        }
        .onChange(of: editingAddress) { _, editing in
            if !editing { address = tab.address?.absoluteString ?? "" }
        }
        .alert("Enter a valid web address", isPresented: $invalidAddress) {
            Button("OK") { focusAddress() }
        } message: { Text("Use an HTTP or HTTPS address, or a local address such as localhost:3000.") }
    }

    private func navigate() {
        guard let url = WorkspaceBrowser.webAddress(address) else { invalidAddress = true; return }
        editingAddress = false
        address = url.absoluteString
        tab.load(url)
    }

    private func focusAddress() {
        editingAddress = true
        Task { @MainActor in
            await Task.yield()
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.selectAll(nil)
            }
        }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
