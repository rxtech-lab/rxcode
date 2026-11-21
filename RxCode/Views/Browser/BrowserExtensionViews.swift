import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension UTType {
    /// Chrome extension package.
    static let chromeExtensionPackage = UTType(filenameExtension: "crx") ?? .data
}

// MARK: - Toolbar actions

/// Toolbar buttons for extensions that declare an action. Clicking runs the
/// action or opens its popup beneath the button.
struct BrowserExtensionActions: View {
    @Environment(WorkspaceBrowser.self) private var browser
    let manage: () -> Void
    private var manager: BrowserExtensionManager { .shared }

    var body: some View {
        let _ = manager.actionRevision
        if let tab = browser.selectedTab {
            ForEach(manager.installed.filter(\.isEnabled)) { record in
                if let context = manager.contexts[record.id], Self.hasAction(context.webExtension),
                   let action = context.action(for: tab) {
                    ExtensionActionButton(record: record, context: context, action: action, tab: tab, manage: manage)
                }
            }
        }
    }

    static func hasAction(_ webExtension: WKWebExtension) -> Bool {
        ["action", "browser_action", "page_action"].contains { webExtension.manifest[$0] != nil }
    }
}

private struct ExtensionActionButton: View {
    @Environment(WorkspaceBrowser.self) private var browser
    let record: InstalledBrowserExtension
    let context: WKWebExtensionContext
    let action: WKWebExtension.Action
    let tab: WorkspaceBrowserTab
    let manage: () -> Void

    var body: some View {
        Button {
            context.performAction(for: tab)
        } label: {
            ExtensionIcon(image: action.icon(for: CGSize(width: 16, height: 16)), size: 16)
                .frame(width: 25, height: 25)
                .overlay(alignment: .bottomTrailing) {
                    if !action.badgeText.isEmpty {
                        Text(action.badgeText)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .background(.red, in: .capsule)
                            .fixedSize()
                    }
                }
        }
        .buttonStyle(.borderless)
        .disabled(!action.isEnabled)
        .help(action.label.isEmpty ? record.name : action.label)
        .accessibilityLabel(action.label.isEmpty ? record.name : action.label)
        .accessibilityIdentifier("browser-extension-\(record.id)")
        .background(ActionAnchor { BrowserExtensionManager.shared.registerActionAnchor($0, for: record.id) })
        .contextMenu {
            if let options = context.optionsPageURL {
                Button("Options", systemImage: "gearshape") { browser.addTab(url: options) }
            }
            Button("Manage Extensions…", systemImage: "puzzlepiece.extension", action: manage)
        }
    }
}

/// Gives the extension popup an AppKit view to attach to.
private struct ActionAnchor: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { register(view) }
}

private struct ExtensionIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Status overlay

/// Status overlay for the latest extension install or removal.
struct ExtensionStatusOverlay: View {
    private var manager: BrowserExtensionManager { .shared }

    var body: some View {
        if let status = manager.status {
            HStack(spacing: 10) {
                switch status {
                case .working(let message):
                    ProgressView().controlSize(.small)
                    Text(message)
                case .finished(let message):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(message)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).lineLimit(6)
                    Button("Dismiss") { manager.status = nil }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .task(id: status) {
                guard case .finished = status else { return }
                try? await Task.sleep(for: .seconds(3))
                if manager.status == status {
                    withAnimation { manager.status = nil }
                }
            }
        }
    }
}

// MARK: - Manage extensions

/// Lists installed extensions with enable, options, and remove controls.
/// Importing from Chrome opens as a pushed page inside this sheet.
struct BrowserExtensionsSheet: View {
    private enum Route: Hashable { case chromeImport }

    @Environment(WorkspaceBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var removing: InstalledBrowserExtension?
    @State private var choosingFile = false
    private var manager: BrowserExtensionManager { .shared }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if manager.installed.isEmpty {
                    ContentUnavailableView {
                        Label("No Extensions", systemImage: "puzzlepiece.extension")
                    } description: {
                        Text("Import the extensions you use in Chrome, or add an unpacked folder, .crx, or .zip file.")
                    } actions: {
                        Button("Import from Chrome…") { path.append(.chromeImport) }
                        Button("Add from File…") { choosingFile = true }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(manager.installed) { record in
                            ExtensionRow(record: record, context: manager.contexts[record.id], problem: manager.problems[record.id],
                                         openOptions: { url in
                                             browser.addTab(url: url)
                                             dismiss()
                                         },
                                         remove: { removing = record })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Browser Extensions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Import from Chrome…", systemImage: "square.and.arrow.down") { path.append(.chromeImport) }
                        Button("Add from File…", systemImage: "doc.badge.plus") { choosingFile = true }
                    } label: {
                        Label("Add Extension", systemImage: "plus")
                    }
                    .accessibilityIdentifier("browser-extension-add")
                }
            }
            .navigationDestination(for: Route.self) { _ in ChromeExtensionImportSheet() }
            .overlay(alignment: .top) { ExtensionStatusOverlay() }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: manager.status)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .extensionFileImporter(isPresented: $choosingFile)
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { record in
            Button("Remove", role: .destructive) {
                Task { await manager.remove(record.id) }
            }
        } message: { _ in
            Text("The extension’s files and stored data are deleted from RxCode. Chrome isn’t affected.")
        }
    }
}

private struct ExtensionRow: View {
    let record: InstalledBrowserExtension
    let context: WKWebExtensionContext?
    let problem: String?
    let openOptions: (URL) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ExtensionIcon(image: context?.webExtension.icon(for: CGSize(width: 32, height: 32)), size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.body.weight(.medium))
                Text(record.chromeID == nil ? "Version \(record.version)" : "Version \(record.version) · Imported from Chrome")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { record.isEnabled },
                set: { enabled in Task { await BrowserExtensionManager.shared.setEnabled(enabled, for: record.id) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable \(record.name)")
            Menu {
                if let options = context?.optionsPageURL {
                    Button("Options", systemImage: "gearshape") { openOptions(options) }
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([BrowserExtensionManager.shared.folder(for: record.id)])
                }
                Divider()
                Button("Remove…", systemImage: "trash", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(record.name)")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Import from Chrome

/// Chooses a Chrome profile and the extensions to copy into the workspace browser.
struct ChromeExtensionImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profileScan: Result<[ChromeExtensionProfile], Error>?
    @State private var profileID: ChromeExtensionProfile.ID?
    @State private var candidates: [ChromeExtensionCandidate]?
    @State private var selection: Set<ChromeExtensionCandidate.ID> = []
    @State private var choosingFolder = false
    @State private var scanDirectory = ChromeCookieImporter.chromeDirectory
    @State private var scanID = UUID()
    private var manager: BrowserExtensionManager { .shared }

    private var selectedProfile: ChromeExtensionProfile? {
        guard case .success(let profiles)? = profileScan else { return nil }
        return profiles.first { $0.id == profileID }
    }

    private var installedChromeIDs: Set<String> { Set(manager.installed.compactMap(\.chromeID)) }

    var body: some View {
        VStack(spacing: 0) {
            switch profileScan {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error)?:
                profilesUnavailable("Can’t read Chrome profiles", description: Text(error.localizedDescription))
            case .success(let profiles)? where profiles.isEmpty:
                profilesUnavailable(
                    "No Chrome extensions found",
                    description: Text("Install an extension in Chrome, or choose the folder that contains your Chrome profiles.")
                )
            case .success(let profiles)?:
                Form {
                    Section {
                        Picker("Profile", selection: $profileID) {
                            ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    Section {
                        extensionList
                    } header: {
                        Text("Extensions")
                    } footer: {
                        Text("Imported extensions keep the permissions they have in Chrome. RxCode runs them with WebKit, so some Chrome-only features may not work.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Import Extensions from Chrome")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    let chosen = (candidates ?? []).filter { selection.contains($0.id) }
                    dismiss()
                    Task { await manager.importFromChrome(chosen) }
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("chrome-extension-import")
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let directory):
                scanDirectory = directory
                profileScan = nil
                scanID = UUID()
            case .failure(let error):
                profileScan = .failure(error)
            }
        }
        .fileDialogDefaultDirectory(ChromeCookieImporter.chromeDirectory.deletingLastPathComponent())
        .task(id: scanID) {
            let directory = scanDirectory
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BrowserExtensionInstaller.chromeProfiles(in: directory) }
            }.value
            guard !Task.isCancelled else { return }
            profileScan = result
            profileID = (try? result.get())?.first?.id
        }
        .task(id: profileID) {
            candidates = nil
            selection = []
            guard let profile = selectedProfile else { return }
            let directory = profile.directory
            let found = await Task.detached(priority: .userInitiated) {
                BrowserExtensionInstaller.chromeExtensions(in: directory)
            }.value
            guard !Task.isCancelled else { return }
            candidates = found
            selection = Set(found.filter { !installedChromeIDs.contains($0.chromeID) }.map(\.id))
        }
    }

    @ViewBuilder
    private var extensionList: some View {
        if let candidates {
            if candidates.isEmpty {
                Text("This profile has no extensions.").foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { candidate in
                    Toggle(isOn: Binding(
                        get: { selection.contains(candidate.id) },
                        set: { if $0 { selection.insert(candidate.id) } else { selection.remove(candidate.id) } }
                    )) {
                        HStack(spacing: 10) {
                            ExtensionIcon(image: candidate.iconURL.flatMap(NSImage.init(contentsOf:)), size: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.name)
                                Text(installedChromeIDs.contains(candidate.chromeID)
                                     ? "Version \(candidate.version) · Already added, importing updates it"
                                     : "Version \(candidate.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func profilesUnavailable(_ title: LocalizedStringKey, description: Text) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "puzzlepiece.extension")
        } description: {
            description
        } actions: {
            Button("Choose Chrome Folder…") { choosingFolder = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Add from file

extension View {
    /// Picks an unpacked extension folder, `.crx`, or `.zip` and installs it after a permission review.
    func extensionFileImporter(isPresented: Binding<Bool>) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.folder, .chromeExtensionPackage, .zip]) { result in
            switch result {
            case .success(let url):
                Task { await BrowserExtensionManager.shared.install(from: url) }
            case .failure(let error):
                BrowserExtensionManager.shared.status = .failed(error.localizedDescription)
            }
        }
    }
}
