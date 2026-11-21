import AppKit
import MusicKit
import RxCodeChatKit
import RxCodeCore
import SwiftUI

/// The close control removes content; the main button opens the retained presentation.
struct PetPresentationEntry: View {
    let title: String
    let symbol: String
    let isExpanded: Bool
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Label(title, systemImage: symbol)
                    .font(.caption).lineLimit(1).frame(maxWidth: 145)
            }
            .buttonStyle(.plain)
            .help("Open \(title)")
            .accessibilityLabel("Open \(title)")
            Button("Remove \(title)", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .help("Remove \(title) and its bubble")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(isExpanded ? Color.accentColor : Color.primary.opacity(0.15)))
    }
}

struct PetImageBubble: View {
    let item: PetImagePresentation
    let presentation: PetPresentation
    var previewHeight: CGFloat = 250
    @State private var enlarged = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(item.title).font(.headline).lineLimit(2)
                Spacer()
                Button("Close", systemImage: "xmark") { presentation.collapse(item.id) }
                    .labelStyle(.iconOnly).help("Close image").accessibilityLabel("Close image")
            }
            Button { enlarged = true } label: {
                Image(nsImage: item.image).resizable().scaledToFit().frame(maxWidth: 340, maxHeight: previewHeight)
            }
            .buttonStyle(.plain).help("Enlarge image")
            Button("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }
        }
        .padding(14).frame(width: 368)
        .onAppear { presentation.visibleImageID = item.id }
        .onDisappear { if presentation.visibleImageID == item.id { presentation.visibleImageID = nil } }
        .sheet(isPresented: $enlarged) {
            NavigationStack {
                Image(nsImage: item.image).resizable().scaledToFit().padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(item.title)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { enlarged = false } } }
            }
            .frame(minWidth: 560, idealWidth: 900, maxWidth: .infinity, minHeight: 480, idealHeight: 680, maxHeight: .infinity)
        }
    }
}

/// A read-only caption that can wrap within a five-row budget.
struct PetCaptionUIView: View {
    let dialog: AgentUIDialog
    let controller: PetController

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            MarkdownContentView(text: (dialog.captionLines ?? []).joined(separator: "  \n"), style: .rxCodeCompact)
                .frame(width: 190, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Wrapping is expected. Only the entire caption exceeding five rows
                    // needs a larger surface.
                    if height > 90 {
                        controller.appState?.expandPetCaptionToPopover(id: dialog.id)
                    }
                }
                .frame(maxHeight: 90, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
                .allowsHitTesting(false)
            Button {
                controller.appState?.removeAgentUIView(id: dialog.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close UI card")
            .accessibilityLabel("Close UI card")
            .accessibilityIdentifier("pet-inline-ui-close")
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .onAppear { controller.presentation.visibleDialogID = dialog.id }
        .onDisappear { if controller.presentation.visibleDialogID == dialog.id { controller.presentation.visibleDialogID = nil } }
    }
}

struct PetInteractivePopover: View {
    let dialog: AgentUIDialog
    let controller: PetController
    var height: CGFloat = 360
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(dialog.title ?? "Interactive View").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { controller.presentation.collapse(dialog.id) }
                    .help("Close interactive view")
                    .accessibilityIdentifier("pet-presentation-close")
            }.padding(14)
            ClaudeThemeDivider()
            ScrollView { JSONUIRenderer(spec: dialog.spec, interaction: controller.presentation.interaction(for: dialog)).padding(14) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 420, height: height)
        .onAppear { controller.presentation.visibleDialogID = dialog.id }
        .onDisappear { if controller.presentation.visibleDialogID == dialog.id { controller.presentation.visibleDialogID = nil } }
    }
}

struct PetStatusWidgetView: View {
    let controller: PetController
    private var runningTasks: Int {
        guard let state = controller.appState else { return 0 }
        return state.taskBoards.values.flatMap(\.tasks).filter { state.isAgentRunning(for: $0) }.count
    }
    var onSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        Group {
            if let spec = controller.presentation.widget {
                HStack(alignment: .top, spacing: 6) {
                    MarkdownContentView(text: PetWidgetSchema.indicatorText(spec, runningTasks: runningTasks,
                        runningSessions: controller.appState?.inProgressSessionCount ?? 0), style: .rxCodeCompact, expandsHorizontally: false)
                        .font(.caption)
                        .frame(maxWidth: 180, alignment: .leading)
                    Button {
                        controller.presentation.clearWidget()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close status card")
                    .accessibilityLabel("Close status card")
                }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: true)
                    .background(ClaudeTheme.surfacePrimary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(ClaudeTheme.textPrimary.opacity(0.2), lineWidth: 0.75))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
                    .task(id: controller.presentation.widgetRevision) {
                        controller.presentation.visibleWidgetRevision = controller.presentation.widgetRevision
                    }
            }
        }
    }
}

struct PetMusicPlayerView: View {
    let music: PetMusic
    @State private var isHovering = false
    @State private var isEditingVolume = false
    @State private var draftVolume = 0.0
    @State private var editingDeviceID: UInt32?

    init(music: PetMusic, isHovering: Bool = false) {
        self.music = music
        _isHovering = State(initialValue: isHovering)
    }

    private var isWorking: Bool { music.isBusy || music.isTurningOff }
    private var isVolumeExpanded: Bool { isHovering || isEditingVolume }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    artworkView
                    VStack(alignment: .leading, spacing: 2) {
                        Text(music.isLoadingPlayback && !music.ownsQueue ? "Finding song…" : music.title)
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(music.artist.isEmpty ? "Apple Music" : music.artist)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 4)
                Button {
                    Task { _ = try? await music.handle(.object(["action": .string(music.isPlaying ? "pause" : "resume")])) }
                } label: {
                    Group {
                        if isWorking { ProgressView().controlSize(.small) }
                        else { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold)) }
                    }
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking || !music.ownsQueue)
                .help(music.isPlaying ? "Pause" : "Play")
                .sensoryFeedback(.selection, trigger: music.isPlaying)

                Button {
                    Task { _ = await music.off() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(music.isTurningOff)
                .help("Stop music and close")
                .accessibilityLabel("Close music player")
            }
            // Keep the slider mounted for dragging, but collapse its layout
            // space when idle. Finish an active drag before shrinking.
            volumeControl
                .frame(height: isVolumeExpanded ? 20 : 0, alignment: .top)
                .clipped()
                .padding(.top, isVolumeExpanded ? 6 : 0)
            if let error = music.errorMessage {
                Text(error).font(.caption2).foregroundStyle(ClaudeTheme.statusError).lineLimit(3).help(error)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
        )
        .animation(.easeInOut(duration: 0.2), value: isVolumeExpanded)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering && !isEditingVolume { synchronizeVolume() }
        }
        .task(id: isHovering) {
            guard isHovering else { return }
            while !Task.isCancelled {
                if !isEditingVolume { synchronizeVolume() }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
        .overlay(alignment: .top) {
            if let error = music.volumeError {
                Text(error).font(.caption2).foregroundStyle(ClaudeTheme.statusError)
                    .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .offset(y: -34).allowsHitTesting(false)
            }
        }
    }

    private func synchronizeVolume() {
        music.refreshVolume()
        draftVolume = music.volume.level ?? 0
        editingDeviceID = music.volume.deviceID
    }

    private var volumeControl: some View {
        HStack(spacing: 5) {
            Image(systemName: music.volume.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
            Text("Device").font(.system(size: 9))
            Slider(value: Binding(get: { draftVolume }, set: { value in
                draftVolume = value
                music.setVolume(value, deviceID: editingDeviceID)
            }), in: 0...100, onEditingChanged: { editing in
                isEditingVolume = editing
                if !editing { synchronizeVolume() }
            })
            .controlSize(.mini)
            .disabled(!music.volume.canSet)
            .accessibilityLabel("Device output volume")
            .accessibilityValue(music.volume.level.map { "\(Int($0.rounded())) percent" } ?? "Unavailable")
            .accessibilityIdentifier("pet-music-device-volume")
            Text(music.volume.level.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 9).monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .frame(height: 20)
        .help(music.volume.unavailableReason ?? "\(music.volume.deviceName): affects all audio on the default output device, including pet music and voice calls. Does not change mute.")
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering || isEditingVolume)
        .accessibilityHidden(!isHovering)
    }

    @ViewBuilder
    private var artworkView: some View {
        Group {
            if let artwork = music.artwork {
                ArtworkImage(artwork, width: 36, height: 36)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .symbolEffect(.variableColor.iterative, isActive: music.isPlaying && music.artwork == nil)
    }
}

struct PetDesktopActionBadge: View {
    let action: String
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 12
            let symbol = action == "focus" ? "macwindow.on.rectangle" : action == "click" ? "hand.tap.fill" : action == "type" ? "keyboard.fill" : "arrow.\(action).circle.fill"
            Image(systemName: symbol).font(.title.bold()).foregroundStyle(.cyan)
                .padding(7).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                .offset(y: action == "up" ? -abs(sin(phase)) * 8 : action == "down" ? abs(sin(phase)) * 8 : 0)
                .rotationEffect(.degrees(action == "type" ? sin(phase) * 7 : 0))
                .scaleEffect(action == "click" || action == "type" ? 0.9 + abs(sin(phase)) * 0.15 : 1)
        }
        .accessibilityLabel("Desktop action: \(action)")
    }
}
