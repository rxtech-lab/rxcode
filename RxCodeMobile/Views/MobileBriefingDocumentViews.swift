import SwiftUI
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import TipKit

struct MobileDocumentBriefingCard: View {
    let document: MobileBriefingDocument
    var projectName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: document.format == "html" ? "doc.richtext" : "doc.text")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.indigo)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(projectName ?? String(localized: "Document"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if projectName != nil {
                    Label("Document", systemImage: "doc.text")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .mobileCardChipBackground()
                }
                Spacer(minLength: 0)
                Text(document.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mobileCardSurface()
    }
}

struct MobileDocumentBriefingDetailView: View {
    @EnvironmentObject private var state: MobileAppState
    let document: MobileBriefingDocument
    @State private var content: String?
    @State private var assets: [MobileBriefingAsset] = []
    @State private var error: String?
    @State private var selectedAsset: MobileBriefingAsset?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(document.title).font(.title2.bold())
                if let content {
                    if document.format == "html" {
                        Text(attributedHTML(content))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Full block markdown (headings, tables, lists, code)
                        // instead of Text's inline-only markdown.
                        MarkdownContentView(text: content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let error {
                    ContentUnavailableView("Unable to Load Briefing", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
                if !assets.isEmpty {
                    Divider()
                    Text("Files").font(.headline)
                    ForEach(assets) { asset in
                        Button {
                            selectedAsset = asset
                        } label: {
                            Label(asset.path, systemImage: "paperclip")
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(MobileCard.pageBackground)
        .navigationTitle(document.title)
        .accessibilityIdentifier("briefing-document-detail")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: document.updatedAt) {
            content = nil
            error = nil
            await state.requestBriefingContent(id: document.id)
        }
        .onChange(of: state.briefingContentResult?.clientRequestID) { _, _ in
            guard let result = state.briefingContentResult,
                  result.briefingID == document.id,
                  result.assetPath == nil else { return }
            if result.ok {
                content = result.content ?? ""
                assets = result.assets ?? []
            } else {
                error = result.errorMessage ?? "The briefing is unavailable."
            }
        }
        .sheet(item: $selectedAsset) { asset in
            MobileBriefingAssetSheet(documentID: document.id, asset: asset)
        }
    }

    private func attributedHTML(_ source: String) -> AttributedString {
        guard let rendered = try? NSAttributedString(
            data: Data(source.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) else { return AttributedString(source) }
        return AttributedString(rendered)
    }
}

struct MobileBriefingAssetSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID
    let asset: MobileBriefingAsset
    @State private var localURL: URL?
    @State private var previewImage: UIImage?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let previewImage {
                    Image(uiImage: previewImage).resizable().scaledToFit()
                } else if let error {
                    ContentUnavailableView("Unable to Load File", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if localURL != nil {
                    ContentUnavailableView(asset.path, systemImage: "doc", description: Text("Use Share to open this file."))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(asset.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let localURL {
                    ToolbarItem(placement: .confirmationAction) { ShareLink(item: localURL) }
                }
            }
        }
        .task { await state.requestBriefingContent(id: documentID, assetPath: asset.path) }
        .onChange(of: state.briefingContentResult?.clientRequestID) { _, _ in
            guard let result = state.briefingContentResult,
                  result.briefingID == documentID,
                  result.assetPath == asset.path else { return }
            guard result.ok, let url = state.briefingAssetFileURL else {
                error = result.errorMessage ?? "The file is unavailable."
                return
            }
            localURL = url
            previewImage = UIImage(contentsOfFile: url.path)
        }
    }
}
