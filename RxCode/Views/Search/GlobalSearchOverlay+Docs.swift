import SwiftUI
import RxCodeCore

extension GlobalSearchOverlay {
    // MARK: - Docs section

    var docsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Text("Documentation")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .textCase(.uppercase)
                Text("· \(docsHits.count)")
                    .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(docsHits) { hit in
                    docsRow(hit: hit)
                }
            }
        }
    }

    private func docsRow(hit: DocsSearchHit) -> some View {
        let row: SelectableRow = .doc(hit.id)
        let isSelected = currentSelection() == row
        return Button {
            selectedDoc = hit
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: ClaudeTheme.size(13)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(hit.title ?? hit.docId)
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        if let score = hit.score { scoreBadge(Float(score)) }
                    }
                    if let repo = hit.repository {
                        Text(repo)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    if let snippet = hit.snippet, !snippet.isEmpty {
                        Text(Self.inlineMarkdown(snippet))
                            .font(.system(size: ClaudeTheme.size(12)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
        .id(row)
    }
}
