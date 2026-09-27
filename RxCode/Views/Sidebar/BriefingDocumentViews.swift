import SwiftUI
import WebKit
import RxCodeCore
import RxCodeChatKit

// MARK: - Card

/// Briefing-tab card for an agent-written document briefing. The body is read
/// from disk only once the card is actually rendered by the lazy grid.
struct BriefingDocumentCard: View {
    @Environment(AppState.self) private var appState

    let document: BriefingDocument
    let project: Project?
    let maximumPreviewHeight: CGFloat
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var content: String?
    @State private var copied = false
    @State private var showSendNotification = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BriefingDocumentHeader(document: document, project: project) {
                sendNotificationButton
                copyButton
                actionsMenu
            }

            Divider().opacity(0.4)
            preview
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
        .task(id: document.updatedAt) {
            content = await appState.briefingDocumentContent(document)
        }
        .sheet(isPresented: $showSendNotification) {
            SendBriefingNotificationSheet(document: document)
                .environment(appState)
        }
    }

    private var sendNotificationButton: some View {
        Button {
            showSendNotification = true
        } label: {
            BriefingCardIconLabel(systemImage: "paperplane")
        }
        .buttonStyle(.plain)
        .help("Send as notification")
        .accessibilityIdentifier("briefing-send-notification")
    }

    @ViewBuilder
    private var preview: some View {
        if let content {
            let text = document.format == .html ? BriefingHTMLText.plainText(from: content) : content
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("This briefing has no content yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            } else if document.format == .html {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineSpacing(4)
                        .lineLimit(9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    BriefingShowMoreButton(action: onOpen)
                }
            } else {
                BriefingSummaryPreview(text: text, maximumHeight: maximumPreviewHeight, onShowMore: onOpen)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 40)
        }
    }

    private var copyButton: some View {
        Button {
            guard let content, !content.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            BriefingCardIconLabel(systemImage: copied ? "checkmark" : "doc.on.doc", highlighted: copied)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy briefing content")
        .disabled(content?.isEmpty ?? true)
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                onOpen()
            } label: {
                Label("Open Briefing", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([appState.briefingStore.folderURL(for: document.id)])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Briefing…", systemImage: "trash")
            }
        } label: {
            BriefingCardIconLabel(systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions for \(document.title)")
    }
}

/// Title row + chips shared by the document card and its sheet.
struct BriefingDocumentHeader<Actions: View>: View {
    let document: BriefingDocument
    let project: Project?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(ClaudeTheme.accent.opacity(0.12))
                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title.isEmpty ? "Untitled briefing" : document.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(2)
                    Text("Updated \(document.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }

                Spacer(minLength: 0)
                actions()
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                BriefingInfoChip(icon: "doc.text", text: "Document", accented: true)
                if let project {
                    BriefingInfoChip(icon: "folder.fill", text: project.name)
                }
                BriefingInfoChip(
                    icon: document.format == .html ? "chevron.left.forwardslash.chevron.right" : "text.alignleft",
                    text: document.format == .html ? "HTML" : "Markdown"
                )
            }
        }
    }
}

/// Small bordered square used for the icon buttons in briefing card headers.
struct BriefingCardIconLabel: View {
    let systemImage: String
    var highlighted = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(highlighted ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
            .frame(width: 24, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ClaudeTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
            )
    }
}

// MARK: - Sheet

/// Full view of a document briefing: rendered content plus its stored assets.
struct BriefingDocumentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let document: BriefingDocument
    let project: Project?

    @State private var content: String?
    @State private var assets: [BriefingAsset] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BriefingDocumentHeader(document: document, project: project) {
                EmptyView()
            }
            .padding(24)

            Divider()

            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !assets.isEmpty {
                Divider()
                assetList
            }

            Divider()
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([appState.briefingStore.folderURL(for: document.id)])
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 420, idealHeight: 660)
        .background(ClaudeTheme.background)
        .task(id: document.updatedAt) {
            async let body = appState.briefingDocumentContent(document)
            async let files = appState.briefingDocumentAssets(document)
            content = await body
            assets = await files
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if content == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if document.format == .html {
            BriefingHTMLView(fileURL: appState.briefingStore.contentURL(for: document))
        } else {
            ScrollView {
                // Full markdown renderer so tables, code blocks, and images
                // render in the sheet; cards keep the lightweight preview.
                MarkdownContentView(
                    text: GeneratedTextSanitizer.cleanMarkdownDocument(content ?? ""),
                    baseURL: appState.briefingStore.contentURL(for: document).deletingLastPathComponent()
                )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
            }
        }
    }

    private var assetList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(assets) { asset in
                    Button {
                        NSWorkspace.shared.open(appState.briefingStore.assetURL(asset, in: document.id))
                    } label: {
                        BriefingInfoChip(icon: Self.icon(for: asset.kind), text: asset.fileName)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(asset.fileName)")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }

    private static func icon(for kind: BriefingAssetKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .file: "paperclip"
        }
    }
}

// MARK: - HTML

/// Renders an HTML briefing from disk, allowing it to load sibling assets
/// (`images/…`, `videos/…`) from the briefing folder.
struct BriefingHTMLView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != fileURL {
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }
}

enum BriefingHTMLText {
    /// Rough plain-text rendering of HTML for card previews: drops
    /// script/style blocks and tags, decodes common entities, and collapses
    /// whitespace.
    static func plainText(from html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<(script|style|head)[^>]*>[\\s\\S]*?</\\1>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/h[1-6]|/li|/tr)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
