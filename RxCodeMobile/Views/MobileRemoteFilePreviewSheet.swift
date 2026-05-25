import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

struct MobileRemoteFilePreviewSheet: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    let link: LocalFileLink
    @State private var lineDisplay: DiffView.LineDisplay = .wrap

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            lineDisplay = (lineDisplay == .wrap) ? .scroll : .wrap
                        } label: {
                            Image(
                                systemName: lineDisplay == .wrap
                                    ? "arrow.left.and.right"
                                    : "text.alignleft"
                            )
                        }
                        .accessibilityLabel(
                            lineDisplay == .wrap
                                ? "Switch to horizontal scroll"
                                : "Switch to wrap"
                        )

                        Button("Done") { dismiss() }
                    }
                }
        }
        .task(id: link.id) {
            await state.requestRemoteFile(path: link.path, line: link.line)
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoadingRemoteFile && state.remoteFileResult == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = state.remoteFileResult, result.path == link.path {
            if result.ok, let text = result.content {
                codeView(text, truncated: result.truncated)
            } else {
                errorView(result.errorMessage ?? "Could not load this file.")
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func codeView(_ text: String, truncated: Bool) -> some View {
        VStack(spacing: 0) {
            if truncated {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("File preview truncated.")
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }

            DiffView(
                lines: codeLines(in: text),
                showsDiffMarkers: false,
                display: lineDisplay,
                language: SyntaxHighlighter.language(forFilename: link.path)
            )
        }
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Load File", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task { await state.requestRemoteFile(path: link.path, line: link.line) }
            }
        }
    }

    private var fileName: String {
        URL(fileURLWithPath: link.path).lastPathComponent
    }

    private func codeLines(in text: String) -> [DiffLine] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let content = lines.isEmpty ? [""] : lines
        return content.enumerated().map { index, line in
            DiffLine(
                text: line,
                kind: .context,
                oldLineNumber: nil,
                newLineNumber: index + 1
            )
        }
    }
}
