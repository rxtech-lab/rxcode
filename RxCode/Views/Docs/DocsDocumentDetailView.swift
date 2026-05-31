import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// Read-only viewer for a single document. Loads the full markdown from the
/// docs service and offers a version picker that swaps in any historical
/// version's content. Used from both ⌘K docs search and the docs manager.
struct DocsDocumentDetailView: View {
    /// Internal docs-repo UUID or `owner/repo` — both are accepted by the API.
    /// When `nil` we can't fetch (e.g. a search hit with no repo), so we render
    /// `fallbackContent` only.
    let repoId: String?
    let docId: String
    var fallbackTitle: String?
    /// Shown when the full document can't be fetched (e.g. the search snippet).
    var fallbackContent: String?
    var originalLink: String?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [DocsDocumentVersion] = []
    @State private var currentVersion: Int?
    @State private var selectedVersion: Int?
    @State private var contentByVersion: [Int: String] = [:]
    @State private var resolvedOriginalLink: String?
    @State private var isLoading = false
    @State private var isLoadingVersion = false
    @State private var errorMessage: String?

    private var title: String { fallbackTitle ?? docId }

    private var displayedContent: String? {
        if let v = selectedVersion, let cached = contentByVersion[v] { return cached }
        return nil
    }

    private var link: URL? {
        guard let s = resolvedOriginalLink ?? originalLink, let url = URL(string: s) else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: displayedContent)
        }
        .frame(width: 680, height: 600)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                    .lineLimit(2)
                Text(docId)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if versions.count > 1 {
                versionPicker
            }
            if let link {
                Link("Open", destination: link)
            }
            Button("Done") { dismiss() }
        }
        .padding(16)
    }

    private var versionPicker: some View {
        Picker("Version", selection: Binding(
            get: { selectedVersion ?? currentVersion ?? 0 },
            set: { newValue in
                selectedVersion = newValue
                Task { await loadVersion(newValue) }
            }
        )) {
            ForEach(versions) { v in
                Text(versionLabel(v)).tag(v.version)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 160)
        .disabled(isLoadingVersion)
    }

    private func versionLabel(_ v: DocsDocumentVersion) -> String {
        v.version == currentVersion ? "v\(v.version) (current)" : "v\(v.version)"
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for content: String?) -> some View {
        if isLoading {
            VStack { Spacer(); ProgressView(); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                ZStack(alignment: .top) {
                    MarkdownContentView(text: content ?? fallbackContent ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    if isLoadingVersion {
                        ProgressView().controlSize(.small).padding(.top, 12)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let repoId else { return } // No repo → fallbackContent only.
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let detailTask = appState.docs.getDocument(repoId: repoId, docId: docId)
            async let versionsTask = appState.docs.listDocumentVersions(repoId: repoId, docId: docId)
            let detail = try await detailTask
            let cur = detail.document.currentVersion ?? detail.currentVersion?.version
            currentVersion = cur
            selectedVersion = cur
            if let cur, let body = detail.currentVersion?.content {
                contentByVersion[cur] = body
            }
            if let resolved = detail.document.originalLink, !resolved.isEmpty {
                resolvedOriginalLink = resolved
            }
            versions = (try? await versionsTask) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadVersion(_ version: Int) async {
        guard let repoId, contentByVersion[version] == nil else { return }
        isLoadingVersion = true
        defer { isLoadingVersion = false }
        do {
            let v = try await appState.docs.getDocumentVersion(repoId: repoId, docId: docId, version: version)
            if let body = v.content { contentByVersion[version] = body }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
