import SwiftUI
#if os(macOS)
import AppKit
import RxCodeCore

/// Detail preview sheet for image attachments
struct ImagePreviewSheet: View {
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: ClaudeTheme.size(16)))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                if let data = attachment.imageData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 48))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                        Text("Image unavailable", bundle: .module)
                            .font(.system(size: ClaudeTheme.size(13)))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .padding(40)
                }
            }
            .background(ClaudeTheme.background)
        }
        .frame(minWidth: 480, idealWidth: 720, minHeight: 360, idealHeight: 540)
        .background(ClaudeTheme.surfaceElevated)
    }
}
#endif
