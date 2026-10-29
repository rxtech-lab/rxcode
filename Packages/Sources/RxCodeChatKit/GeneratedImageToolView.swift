import SwiftUI
import ImageIO
import RxCodeCore

/// A generated image stays visible in the conversation after the tool completes.
struct GeneratedImageToolView: View {
    let toolCall: ToolCall
    let isStreaming: Bool
    @State private var image: Image?
    @State private var isLoadingImage = false
    @State private var showsPreview = false
    @State private var isHovering = false

    private static let maxWidth: CGFloat = 480
    private static let placeholderHeight: CGFloat = 270

    private enum Phase { case generating, ready, failed }

    private var output: [String: JSONValue] {
        guard let result = toolCall.result, let data = result.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    private var path: String? { output["savedPath"]?.stringValue }

    private var revisedPrompt: String? {
        let prompt = output["revisedPrompt"]?.stringValue ?? toolCall.input["prompt"]?.stringValue
        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return prompt
    }

    private var phase: Phase {
        if image != nil { return .ready }
        if isLoadingImage || (toolCall.result == nil && isStreaming) { return .generating }
        return .failed
    }

    private var failureMessage: String {
        output["displayError"]?.stringValue
            ?? (toolCall.isError ? String(localized: "Image generation failed") : String(localized: "Image not available"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let revisedPrompt, phase != .failed {
                Text(revisedPrompt)
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(revisedPrompt)
            }
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .bubbleStyle(phase == .failed ? .toolError : .tool)
        .padding(.vertical, 6)
        .animation(.smooth(duration: 0.3), value: phase)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: showsPreview)
        .sensoryFeedback(.success, trigger: phase == .ready)
        #endif
        .task(id: path) { await loadImage() }
        .sheet(isPresented: $showsPreview) { previewSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: phase == .failed ? "exclamationmark.triangle.fill" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(phase == .failed ? ClaudeTheme.statusError : ClaudeTheme.accent)
                .frame(width: 28, height: 28)
                .background(
                    (phase == .failed ? ClaudeTheme.statusError : ClaudeTheme.accent).opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .symbolEffect(.pulse, isActive: phase == .generating)

            VStack(alignment: .leading, spacing: 1) {
                Text("Generated image")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)

            if phase == .ready {
                Button {
                    showsPreview = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .help("Open preview")
                .accessibilityLabel("Open preview")
            }
        }
    }

    private var statusText: LocalizedStringKey {
        switch phase {
        case .generating: "Generating image…"
        case .ready: "Click to preview"
        case .failed: "Couldn't show image"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:
            if let image {
                Button {
                    showsPreview = true
                } label: {
                    image.resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .background(ClaudeTheme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
                        .overlay {
                            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                                .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
                        }
                        .scaleEffect(isHovering ? 1.01 : 1)
                        .shadow(color: .black.opacity(isHovering ? 0.18 : 0), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .accessibilityLabel("Preview generated image")
            }
        case .generating:
            GeneratingImagePlaceholder()
                .frame(maxWidth: .infinity)
                .frame(height: Self.placeholderHeight)
                .transition(.opacity)
        case .failed:
            Text(failureMessage)
                .font(.callout)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - Preview

    private var previewSheet: some View {
        NavigationStack {
            Group {
                if let image {
                    image.resizable().scaledToFit()
                } else {
                    ContentUnavailableView("Image not available", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle("Generated image")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showsPreview = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 720, minHeight: 400, idealHeight: 600)
        #endif
    }

    // MARK: - Loading

    private func loadImage() async {
        image = nil
        guard let path else { return }
        isLoadingImage = true
        defer { isLoadingImage = false }
        let thumbnail = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil as CGImage? }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2400,
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard !Task.isCancelled else { return }
        if let thumbnail { image = Image(decorative: thumbnail, scale: 1) }
    }
}

/// Framed canvas with a soft moving sheen, shown while the image renders.
private struct GeneratingImagePlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        ZStack {
            shape.fill(ClaudeTheme.surfaceSecondary)

            if !reduceMotion {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, ClaudeTheme.accent.opacity(0.12), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.6)
                }
                .clipShape(shape)
            }

            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .overlay { shape.strokeBorder(ClaudeTheme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Generating image")
    }
}
