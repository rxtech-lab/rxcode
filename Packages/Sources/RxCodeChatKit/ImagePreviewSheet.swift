import SwiftUI
#if os(macOS)
import AppKit
import RxCodeCore

/// Detail preview sheet for image attachments
public struct ImagePreviewSheet: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    public init(attachment: Attachment) {
        self.attachment = attachment
    }

    /// In-memory data first (a pasted image), then the file on disk.
    private var image: NSImage? {
        if let data = attachment.imageData, let image = NSImage(data: data) { return image }
        guard !attachment.path.isEmpty else { return nil }
        return NSImage(contentsOfFile: attachment.path)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "photo.fill")
                    .foregroundStyle(ClaudeTheme.accent)
                Text(attachment.name)
                    .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button { zoom = max(0.25, zoom / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(zoom <= 0.25)
                .help(String(localized: "Zoom out", bundle: .module))

                Text(zoom, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(width: 48)

                Button { zoom = min(8, zoom * 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(zoom >= 8)
                .help(String(localized: "Zoom in", bundle: .module))

                Button { zoom = 1 } label: {
                    Text("Fit", bundle: .module)
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ClaudeTheme.size(16)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Close preview", bundle: .module))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            GeometryReader { geometry in
                if let nsImage = image {
                    let fit = min((geometry.size.width - 32) / max(1, nsImage.size.width),
                                  (geometry.size.height - 32) / max(1, nsImage.size.height))
                    let scale = max(0.25, min(8, zoom * magnification))
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: max(1, nsImage.size.width * fit * scale),
                                   height: max(1, nsImage.size.height * fit * scale))
                            .padding(16)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .gesture(MagnifyGesture()
                        .updating($magnification) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = max(0.25, min(8, zoom * value.magnification)) })
                } else {
                    ContentUnavailableView {
                        Label { Text("Image unavailable", bundle: .module) } icon: { Image(systemName: "photo") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(ClaudeTheme.background)
        }
        .frame(minWidth: 600, idealWidth: 900, maxWidth: .infinity,
               minHeight: 440, idealHeight: 680, maxHeight: .infinity)
        .background(ClaudeTheme.surfaceElevated)
    }
}
#endif
