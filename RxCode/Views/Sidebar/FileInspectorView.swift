import SwiftUI
import AppKit
import RxCodeCore

extension View {
    func fileInspectorSheet(_ window: WindowState) -> some View {
        sheet(item: Bindable(window).inspectorFile) { file in
            FileInspectorView(filePath: file.path, fileName: file.name, onClose: { window.inspectorFile = nil }) {
                FilePreviewTitle(fileName: file.name)
            }
            .frame(minWidth: 1000, idealWidth: 1400, maxWidth: 1920,
                   minHeight: 600, idealHeight: 1000, maxHeight: 1200)
            .onExitCommand { window.inspectorFile = nil }
        }
    }
}

/// Inspector panel for file preview with syntax highlighting
struct FileInspectorView<Title: View>: View {
    let filePath: String
    let fileName: String
    let onClose: () -> Void
    @ViewBuilder var title: () -> Title
    @State private var content: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isCopied = false
    @State private var showsRawText = false
    @State private var usesNativePreview = false
    @State private var capture = PreviewCapture()
    @State private var isEditing = false
    @State private var editingContent = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var sourceEncoding = String.Encoding.utf8
    @State private var sourceBOM = Data()

    private var isDirty: Bool {
        isEditing && editingContent != (content ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ClaudeThemeDivider()

            Group {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else if usesNativePreview || (format == .native && !showsRawText) {
                    NativeFilePreviewView(fileURL: fileURL, capture: capture)
                        .id(filePath + String(content?.hashValue ?? 0))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content {
                    Group {
                        if showsRawText || !format.hasRenderedPreview {
                            ThemedSourcePreview(text: content, language: fileExtension)
                        } else if format == .markdown {
                            MarkdownPreviewView(content: content, baseURL: fileURL.deletingLastPathComponent())
                        } else if format == .html {
                            HTMLFilePreviewView(fileURL: fileURL, content: content)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .previewSelectionComments(for: fileURL)
                    .id(showsRawText)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isCopied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.callout).padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding(8).allowsHitTesting(false)
                }
            }
        }
        .background(ClaudeTheme.background)
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                editingView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Edit \(fileName)")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isEditing = false }
                                .keyboardShortcut(.cancelAction)
                                .disabled(isSaving)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { Task { await saveFile() } }
                                .keyboardShortcut("s", modifiers: .command)
                                .disabled(!isDirty || isSaving)
                        }
                    }
            }
            .frame(minWidth: 640, minHeight: 480)
            .interactiveDismissDisabled(isDirty || isSaving)
            .overlay {
                if isSaving {
                    ProgressView("Saving…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
        .task(id: filePath) {
            isEditing = false
            editingContent = ""
            saveError = nil
            await loadFile()
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)
        .background(ClaudeTheme.surfacePrimary)
        .task { ExternalEditorService.shared.detectIfNeeded() }
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 8) {
            title()
                .help(filePath)
            Spacer(minLength: 0)
            if content != nil && format.hasRenderedPreview {
                FilePreviewModeTabs(showsRawText: $showsRawText, compact: compact)
                Divider().frame(height: 16)
            }
            HStack(spacing: 2) {
                if !isLoading && errorMessage == nil && (usesNativePreview || (format == .native && !showsRawText)) {
                    PreviewCommentControls(url: fileURL, capture: capture)
                        .buttonStyle(.borderless).controlSize(.small)
                }
                if let content {
                    WorkspaceTabStripButton(systemImage: "pencil", help: "Edit File") {
                        editingContent = content
                        isEditing = true
                    }
                    if !compact {
                        WorkspaceTabStripButton(systemImage: "doc.on.doc", help: "Copy File Contents") {
                            copyToClipboard(content, feedback: $isCopied)
                        }
                    }
                }
                Menu {
                    if compact, let content {
                        Button("Copy File Contents", systemImage: "doc.on.doc") {
                            copyToClipboard(content, feedback: $isCopied)
                        }
                        Divider()
                    }
                    Button("Open in Default App", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(fileURL) }
                    let editors = ExternalEditorService.shared.detectedEditors
                    if !editors.isEmpty {
                        Menu("Open in Editor") {
                            ForEach(editors) { editor in
                                Button(editor.displayName, systemImage: editor.systemSymbol) {
                                    ExternalEditorService.shared.open(editor, path: filePath)
                                }
                            }
                        }
                    }
                    Button("Reveal in Finder", systemImage: "folder") { ExternalEditorService.shared.revealInFinder(filePath) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More File Actions").help("More File Actions")
                WorkspaceTabStripButton(systemImage: "xmark", help: "Close Preview", action: onClose)
            }
            .fixedSize()
        }
        .frame(minHeight: 28)
    }

    // MARK: - Content

    private var editingView: some View {
        VStack(spacing: 0) {
            TextEditor(text: $editingContent)
                .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(ClaudeTheme.codeBackground)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
        }
        .background(ClaudeTheme.codeBackground)
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: ClaudeTheme.size(24)))
                .foregroundStyle(ClaudeTheme.statusWarning)
            Text(message)
                .font(.system(size: ClaudeTheme.size(13)))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File Saving

    private func saveFile() async {
        guard isDirty, !isSaving else { return }
        isSaving = true
        saveError = nil
        let textToSave = editingContent
        let path = filePath
        let encoding = sourceEncoding
        let bom = sourceBOM
        do {
            try await Task.detached {
                let url = URL(fileURLWithPath: path)
                guard let encoded = textToSave.data(using: encoding) else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                try (bom + encoded).write(to: url, options: .atomic)
            }.value
            content = textToSave
            isEditing = false
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
        isSaving = false
    }

    // MARK: - File Loading

    private func loadFile() async {
        isLoading = true
        content = nil
        errorMessage = nil
        showsRawText = false
        sourceEncoding = .utf8
        sourceBOM = Data()
        usesNativePreview = !format.canReadSource(fileName: fileName)
        if usesNativePreview {
            if !FileManager.default.isReadableFile(atPath: filePath) {
                errorMessage = "The file cannot be read. It may have been moved or deleted."
            }
            isLoading = false
            return
        }

        do {
            let data = try await Task.detached { [filePath] in
                let url = URL(fileURLWithPath: filePath)
                let attr = try FileManager.default.attributesOfItem(atPath: filePath)
                let size = (attr[.size] as? Int) ?? 0
                if size > 5_000_000 {
                    throw FileInspectorError.tooLarge
                }
                return try Data(contentsOf: url)
            }.value

            try Task.checkCancellation()
            if let text = FilePreviewFormat.decodeSource(data) {
                content = text
                if data.starts(with: [0xFF, 0xFE]) {
                    sourceEncoding = .utf16LittleEndian
                    sourceBOM = Data([0xFF, 0xFE])
                } else if data.starts(with: [0xFE, 0xFF]) {
                    sourceEncoding = .utf16BigEndian
                    sourceBOM = Data([0xFE, 0xFF])
                } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                    sourceBOM = Data([0xEF, 0xBB, 0xBF])
                }
            } else {
                usesNativePreview = true
            }
        } catch is CancellationError {
            return
        } catch is FileInspectorError {
            errorMessage = "File is too large (>5MB)"
        } catch {
            errorMessage = "Read failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Helpers

    private var fileURL: URL { URL(fileURLWithPath: filePath) }

    private var format: FilePreviewFormat { FilePreviewFormat(fileName: fileName) }

    private var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }
}

private enum FileInspectorError: Error {
    case tooLarge
}

struct FilePreviewTitle: View {
    let fileName: String

    var body: some View {
        let file = FileNode(id: fileName, name: fileName, isDirectory: false, children: [])
        HStack(spacing: 7) {
            Image(systemName: file.icon)
                .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                .foregroundStyle(file.iconColor)
                .frame(width: 24, height: 24)
                .background(ClaudeTheme.surfaceSecondary, in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(verbatim: fileName)
                .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct FilePreviewModeTabs: View {
    @Binding var showsRawText: Bool
    let compact: Bool
    @State private var hoveredTab: Bool?

    var body: some View {
        HStack(spacing: 2) {
            tab("Preview", systemImage: "eye", raw: false)
            tab("Raw Text", systemImage: "chevron.left.forwardslash.chevron.right", raw: true)
        }
        .padding(2)
        .background(ClaudeTheme.surfaceSecondary, in: .rect(cornerRadius: 8))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
        .accessibilityIdentifier("file-preview-mode")
    }

    private func tab(_ title: LocalizedStringKey, systemImage: String, raw: Bool) -> some View {
        let selected = showsRawText == raw
        return Button { showsRawText = raw } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                if !compact { Text(title) }
            }
            .font(.system(size: ClaudeTheme.size(11), weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
            .padding(.horizontal, compact ? 6 : 8)
            .frame(minWidth: 26, minHeight: 24)
            .workspaceTabChip(selected: selected, hovered: hoveredTab == raw, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hoveredTab = inside ? raw : nil }
        .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }
}
