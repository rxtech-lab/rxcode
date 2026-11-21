#if os(macOS)
import AVKit
import SwiftUI
import RxCodeCore
import AppKit

// MARK: - Generations list

struct VideoTakeList: View {
    let takes: [VideoTake]
    let selectedID: UUID?
    let statuses: [String: String]
    /// The selected generation's activity log.
    let activity: [VideoGenerationActivity]
    let select: (UUID) -> Void

    @State private var showsActivity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Generations", bundle: .module)
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Spacer()
                Text("\(takes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ClaudeTheme.textTertiary)
                Button {
                    showsActivity.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Generation activity", bundle: .module))
                .accessibilityLabel(Text("Generation activity", bundle: .module))
                .popover(isPresented: $showsActivity, arrowEdge: .bottom) {
                    VideoActivityPopover(activity: activity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(takes.reversed()) { take in
                            VideoTakeRow(
                                take: take,
                                isSelected: take.id == selectedID,
                                status: take.toolCall.flatMap { statuses[$0.id] },
                                parentPrompt: parentPrompt(of: take)
                            )
                            .id(take.id)
                            .modifier(VideoFileActions(path: take.phase == .ready ? take.path : nil, select: { select(take.id) }, continues: true))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .onChange(of: takes.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(ClaudeTheme.sidebarBackground)
    }

    /// The prompt of the clip whose last frame started this one.
    private func parentPrompt(of take: VideoTake) -> String? {
        guard let source = take.sourcePath else { return nil }
        return takes.first { $0.path.map(StudioContinuation.lastFramePath(forVideoAt:)) == source }?.prompt
    }
}

/// The selected generation's steps, newest first: what RxCode did and what
/// the task model is doing while it looks up the companion files.
struct VideoActivityPopover: View {
    let activity: [VideoGenerationActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Activity", bundle: .module)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            ClaudeThemeDivider()
            if activity.isEmpty {
                ContentUnavailableView {
                    Label { Text("No Activity Yet", bundle: .module) } icon: { Image(systemName: "list.bullet.rectangle") }
                } description: {
                    Text("Steps appear here while a video is being prepared and rendered.", bundle: .module)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(activity.reversed()) { entry in
                            VideoActivityRow(entry: entry, isLatest: entry.id == activity.last?.id)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 360, height: 360)
    }
}

private struct VideoActivityRow: View {
    let entry: VideoGenerationActivity
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.actor == nil ? "gearshape" : "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(entry.actor == nil ? ClaudeTheme.textTertiary : ClaudeTheme.accent)
                .symbolEffect(.pulse, isActive: isLatest && entry.actor != nil)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.message)
                    .font(.system(size: ClaudeTheme.size(12), weight: isLatest ? .medium : .regular))
                    .foregroundStyle(isLatest ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text([entry.actor, entry.date.formatted(.dateTime.hour().minute().second())]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct VideoTakeRow: View {
    let take: VideoTake
    let isSelected: Bool
    let status: String?
    let parentPrompt: String?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VideoThumbnail(take: take)
                .frame(width: 80, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(take.prompt.isEmpty ? String(localized: "Untitled prompt", bundle: .module) : take.prompt)
                    .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let source = take.sourcePath {
                    StudioParentLine(path: source, prompt: parentPrompt)
                }
                statusLine
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? ClaudeTheme.sidebarItemSelected : (isHovered ? ClaudeTheme.sidebarItemHover : .clear),
            in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch take.phase {
        case .generating:
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = VideoProgressStatus.fraction(in: status) {
                    ProgressView(value: fraction).controlSize(.mini)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.mini)
                }
                Text(status ?? String(localized: "Preparing…", bundle: .module))
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            .tint(ClaudeTheme.accent)
        case .ready:
            Text([take.date.formatted(.dateTime.hour().minute()), take.elapsedSeconds.map(VideoStudioFormat.madeIn)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.textTertiary)
        case .missing:
            Text("File missing", bundle: .module)
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.statusWarning)
        case .failed:
            Text("Failed", bundle: .module)
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.statusError)
        }
    }
}

/// First frame of a finished clip, or a phase glyph.
private struct VideoThumbnail: View {
    let take: VideoTake
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(ClaudeTheme.surfaceTertiary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(take.phase == .failed ? ClaudeTheme.statusError : ClaudeTheme.textSecondary)
                    .symbolEffect(.pulse, isActive: take.phase == .generating)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
        }
        .task(id: take.phase == .ready ? take.path : nil) {
            guard take.phase == .ready, let path = take.path else { image = nil; return }
            image = await Self.firstFrame(of: URL(fileURLWithPath: path))
        }
    }

    private var glyph: String {
        switch take.phase {
        case .generating: "film.stack"
        case .ready: "play.fill"
        case .missing: "questionmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    static func firstFrame(of url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let (cgImage, _) = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
#endif
