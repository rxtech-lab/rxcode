import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspacePreviewInspector: View {
    @Environment(WorkspaceDesignSession.self) private var design
    @Environment(WindowState.self) private var window
    @State private var picker: PickerKind?
    @State private var importing = false
    @State private var designing = false
    @State private var capture = PreviewCapture()

    private enum PickerKind: String, Identifiable { case device, swift; var id: Self { self } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    Button("Simulator or Mac Window…") { picker = .device }
                    Button("SwiftUI Preview…") { picker = .swift }.disabled(window.selectedProject == nil)
                    Button("Open Document…") { importing = true }
                } label: {
                    Label(design.source?.title ?? "Choose preview", systemImage: "rectangle.on.rectangle")
                        .lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).accessibilityLabel("Choose preview source")
                Spacer(minLength: 0)
                if case .document(let url) = design.source {
                    if !Self.usesFileViewer(url) { PreviewCommentControls(url: url, capture: capture) }
                }
                else if let source = design.source {
                    Toggle(isOn: $designing) { Image(systemName: "scope") }.toggleStyle(.button)
                        .disabled(design.image == nil).help("Select an element for refinement").accessibilityLabel("Design")
                    Button { Task { await design.open(source) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(design.loading).accessibilityLabel("Refresh preview")
                }
            }
            .controlSize(.small).padding(10)
            Divider()
            Group {
                if let error = design.error {
                    ContentUnavailableView { Label("Preview unavailable", systemImage: "exclamationmark.triangle") }
                        description: { Text(error).textSelection(.enabled) }
                        actions: { if let source = design.source { Button("Retry") { Task { await design.open(source) } } } }
                } else if case .document(let url) = design.source {
                    if Self.usesFileViewer(url) {
                        FileInspectorView(filePath: url.path, fileName: url.lastPathComponent).id(url)
                    } else { NativeFilePreviewView(fileURL: url, capture: capture).id(url) }
                } else if let image = design.image, let source = design.source {
                    GeometryReader { proxy in
                        let scale = min(proxy.size.width / image.size.width, proxy.size.height / image.size.height)
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .overlay {
                                if designing {
                                    DesignSelectionOverlay { point, size in
                                        try await design.selection(point: point, size: size, source: source, image: image)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if !design.loading {
                    ContentUnavailableView("Choose a preview", systemImage: "rectangle.on.rectangle",
                        description: Text("Select a simulator, Mac window, SwiftUI view, or document."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if design.loading { ProgressView("Loading preview…").padding().background(.regularMaterial, in: .rect(cornerRadius: 8)) } }
        }
        .accessibilityIdentifier("workspace-preview-inspector")
        .onChange(of: window.selectedProject?.id) { designing = false }
        .sheet(item: $picker) { kind in
            NavigationStack {
                switch kind {
                case .device: DesignTargetPicker { target in picker = nil; Task { await design.open(.target(target)) } }
                case .swift:
                    if let project = window.selectedProject {
                        SwiftPreviewPicker(root: URL(fileURLWithPath: project.path)) { source in
                            picker = nil
                            Task { await design.open(source) }
                        }
                    }
                }
            }
            .frame(minWidth: 430, idealWidth: 500, minHeight: 430, idealHeight: 580)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            do { let url = try result.get(); Task { await design.open(.document(url)) } }
            catch { if (error as NSError).code != NSUserCancelledError { design.error = error.localizedDescription } }
        }
    }

    private static func usesFileViewer(_ url: URL) -> Bool {
        FilePreviewFormat(fileName: url.lastPathComponent).canReadSource(fileName: url.lastPathComponent)
    }
}

private struct DesignTargetPicker: View {
    let choose: (DesignTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceDesignSession.self) private var design
    @State private var platform = DesignTarget.Platform.iOS
    @State private var targets: [DesignTarget] = []
    @State private var error: String?
    @State private var loading = true
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Platform", selection: $platform) {
                ForEach(DesignTarget.Platform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding()
            if targets.isEmpty {
                ContentUnavailableView {
                    Label(error == nil ? "No running targets" : "Targets unavailable", systemImage: "display")
                } description: {
                    Text(error ?? "Open a simulator, Android emulator, or Mac app, then refresh.")
                } actions: {
                    if platform == .macOS && !ComputerUseWindowCapture.hasAccess {
                        Button("Allow Screen Recording…") { ComputerUseWindowCapture.requestAccess(); refresh += 1 }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(targets) { target in
                    Button { choose(target) } label: {
                        VStack(alignment: .leading) { Text(target.name); Text(target.identifier).font(.caption).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Choose a target")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem { Button("Refresh") { refresh += 1 } }
        }
        .task(id: "\(platform.rawValue)-\(refresh)") {
            targets = []; error = nil; loading = true
            do { let items = try await design.devices.targets(platform); try Task.checkCancellation(); targets = items }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}

private struct SwiftPreviewPicker: View {
    let root: URL
    let choose: (WorkspaceDesignSession.Source) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var index = 0
    @State private var workspace = ""
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        Form {
            LabeledContent("Swift source") { Button(file?.lastPathComponent ?? "Choose File…") { importing = true } }
            Stepper("Preview \(index + 1)", value: $index, in: 0...999)
            TextField("Xcode workspace or tab (optional)", text: $workspace)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped).frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("SwiftUI preview")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Render") { if let file { choose(.swift(file: file, root: root, index: index, workspace: workspace)) } }.disabled(file == nil)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.swiftSource]) { result in
            do { file = try result.get(); error = nil }
            catch { if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription } }
        }
        .fileDialogDefaultDirectory(root)
    }
}
