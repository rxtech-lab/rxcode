import SwiftUI
import WebKit
import RxCodeCore

/// Detects localhost URLs and shows a "View Result" button that,
/// when clicked, provides an in-app web view preview.
struct WebPreviewButton: View {
    let messages: [ChatMessage]
    @State private var showPreview = false
    @State private var previewURL: URL?

    var body: some View {
        if let url = detectedURL {
            Button {
                previewURL = url
                showPreview = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text("View Result", bundle: .module)
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .font(.subheadline)
            }
            .buttonStyle(ClaudeAccentButtonStyle())
            .sheet(isPresented: $showPreview) {
                if let url = previewURL {
                    WebPreviewSheet(url: url)
                }
            }
        }
    }

    private var detectedURL: URL? {
        let allText = messages.map { $0.content }.joined(separator: "\n")
        let pattern = #"https?://(?:localhost|127\.0\.0\.1):\d{2,5}[/\w.-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: allText, range: NSRange(allText.startIndex..., in: allText)),
              let range = Range(match.range, in: allText) else {
            return nil
        }
        return URL(string: String(allText[range]))
    }
}

// MARK: - Web Preview Sheet

struct WebPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "globe")
                    .foregroundStyle(ClaudeTheme.accent)

                Text(url.absoluteString)
                    .font(.subheadline)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Open in browser")

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ClaudeTheme.surfaceElevated)

            ClaudeThemeDivider()

            // Web View
            WebViewWrapper(url: url, isLoading: $isLoading)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - WebView Wrapper

struct WebViewWrapper: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewWrapper

        init(_ parent: WebViewWrapper) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in parent.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in parent.isLoading = false }
        }
    }
}

#Preview {
    WebPreviewButton(messages: [
        ChatMessage(role: .assistant, content: "Server started. Check it at http://localhost:3000."),
    ])
    .padding()
}
