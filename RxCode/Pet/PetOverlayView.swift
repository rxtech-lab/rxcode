import AppKit
import RxAgentVoice
import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - Floating Desktop Pet Overlay View

struct PetOverlayView: View {
    @Bindable var controller: PetController
    let onDragDelta: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onCaptionHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layoutAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }
    private var activityTransition: AnyTransition { reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity) }

    @State private var captionTextHeight: CGFloat = 1
    @State private var isHovering = false
    @State private var dragStartMouseLocation: NSPoint?

    private enum Presentation: Identifiable {
        case confirmation(AgentConfirmation), image(PetImagePresentation), dialog(AgentUIDialog)
        var id: UUID { switch self { case .confirmation(let item): item.id; case .image(let item): item.id; case .dialog(let item): item.id } }
        var isBubble: Bool { switch self { case .confirmation: false; case .image(let item): item.style == "bubble"; case .dialog(let item): item.usesPetCaption } }
    }

    private var activePresentation: Presentation? {
        if let confirmation = pendingConfirmation { return .confirmation(confirmation) }
        if let dialog = controller.appState?.agentPrompts.dialogs.first(where: { $0.isPetPresentation && $0.id == controller.presentation.expandedID }) { return .dialog(dialog) }
        return controller.presentation.images.first(where: { $0.id == controller.presentation.expandedID }).map { .image($0) }
    }

    private var bubbleHeight: CGFloat {
        let visibleHeight = NSScreen.screens.map(\.visibleFrame.height).min() ?? 800
        let speech = activeBubbleText == nil ? 0.0 : 252.0
        let music = controller.music.showsPlayer ? 90.0 : 0.0
        return min(340, max(150, visibleHeight - CGFloat(controller.configuration.petSize) - speech - music - 120))
    }

    private var showsControls: Bool {
        isHovering || controller.isVoiceActive || controller.isStandaloneSpeaking
    }

    var body: some View {
        let presented = activePresentation.flatMap { $0.isBubble ? nil : $0 }
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            // Speech / transcript / tool status bubble above the pet
            if let bubbleText = activeBubbleText {
                speechBubbleView(text: bubbleText)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        ceil(geometry.size.height)
                    } action: { height in
                        onCaptionHeightChange(height)
                    }
                    .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
            }


            if let presentation = activePresentation, presentation.isBubble {
                Group {
                    switch presentation {
                    case .dialog(let item):
                        PetCaptionUIView(dialog: item, controller: controller)
                    case .image(let item): PetImageBubble(item: item, presentation: controller.presentation, previewHeight: max(80, bubbleHeight - 80))
                    case .confirmation: EmptyView()
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)))
                .shadow(radius: 6, y: 2)
            }
            if controller.music.showsPlayer {
                PetMusicPlayerView(music: controller.music)
                    .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
            }


            presentationEntries

            // Animated sprite character
            PetVoiceSprite(controller: controller)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("pet-panel"))
            } action: { frame in
                controller.panelController.updateSpriteFrame(frame)
            }
            .scaleEffect(x: controller.isFacingLeft ? -1 : 1, y: 1)
            .rotationEffect(.degrees(controller.isTakingPhoto ? -6 : 0), anchor: .bottom)
            .scaleEffect(controller.isTakingPhoto ? 0.96 : 1, anchor: .bottom)
            .animation(.easeInOut(duration: 0.18), value: controller.isTakingPhoto)
            .background {
                PetPresentationPanel(id: presented?.id) {
                    Group {
                        switch presented {
                        case .confirmation(let item):
                            if let appState = controller.appState {
                                PetAgentConfirmationSheet(confirmation: item).environment(appState)
                                    .frame(width: 400, height: 420)
                            }
                        case .dialog(let item): PetInteractivePopover(dialog: item, controller: controller)
                        case .image(let item): PetImageBubble(item: item, presentation: controller.presentation)
                        case nil: EmptyView()
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .contentShape(Rectangle())
            .overlay {
                if let action = controller.desktopActions.animation { PetDesktopActionBadge(action: action) }
                if controller.isTakingPhoto {
                    Image(systemName: "camera.fill")
                        .font(.system(size: CGFloat(controller.configuration.petSize) * 0.32, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .rotationEffect(.degrees(-8))
                        .offset(y: CGFloat(controller.configuration.petSize) * 0.12)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Taking a photo")
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "sparkle")
                                .font(.title2.bold())
                                .foregroundStyle(.yellow)
                                .offset(x: 10, y: -12)
                        }
                }
            }
            .onTapGesture(count: 2) {
                controller.toggleVoice()
            }
            .onTapGesture(count: 1) {
                controller.pat()
            }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in
                        if dragStartMouseLocation == nil { controller.screenCapture.cancel(); controller.desktopActions.cancel() }
                        let currentMouse = NSEvent.mouseLocation
                        if let prev = dragStartMouseLocation {
                            let dx = currentMouse.x - prev.x
                            let dy = currentMouse.y - prev.y
                            if abs(dx) > 0.2 || abs(dy) > 0.2 {
                                controller.setWalking(true)
                                onDragDelta(CGSize(width: dx, height: dy))
                            }
                        }
                        dragStartMouseLocation = currentMouse
                    }
                    .onEnded { _ in
                        dragStartMouseLocation = nil
                        controller.setWalking(false)
                        onDragEnded()
                    }
            )
            .contextMenu {
                petContextMenu
            }
            .overlay {
                if !controller.toolActivity.calls.isEmpty {
                    PetToolOrbitView(calls: controller.toolActivity.calls, petSize: CGFloat(controller.configuration.petSize))
                        .transition(activityTransition)
                }
            }
            // Reserve the lower orbit clearance so tools never move the pet itself.
            .padding(.horizontal, 110)
            .padding(.top, controller.toolActivity.calls.isEmpty ? 0 : 60)
            .padding(.bottom, 60)
            .animation(layoutAnimation, value: controller.toolActivity.calls.isEmpty)

            // Sleek quick-action pill below the pet
            if showsControls {
                quickControlsBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Color.clear.frame(height: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(name: "pet-panel")
        .animation(layoutAnimation, value: controller.toolActivity.calls.isEmpty)
        .animation(layoutAnimation, value: captionTextHeight)
        .animation(layoutAnimation, value: activeBubbleText == nil)
        .onChange(of: controller.presentation.images.count) { _, _ in controller.panelController.updatePanelLayout() }
        .onChange(of: controller.appState?.agentPrompts.dialogs.count) { _, _ in controller.panelController.updatePanelLayout() }
        .onChange(of: activePresentation?.id) { _, _ in controller.panelController.updatePanelLayout() }
        .onChange(of: controller.presentation.widgetRevision) { _, _ in controller.panelController.updatePanelLayout() }
        .onChange(of: controller.presentation.widget == nil) { _, _ in controller.panelController.updatePanelLayout() }
        .onChange(of: controller.music.showsPlayer) { _, _ in controller.panelController.updatePanelLayout() }
        .animation(.easeInOut(duration: 0.2), value: controller.music.showsPlayer)
        .alert("Accessibility Access Required", isPresented: Binding(get: { controller.desktopActions.permissionIssue }, set: { controller.desktopActions.permissionIssue = $0 })) {
            Button("Open System Settings") { controller.desktopActions.openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Allow this copy of RxCode in Privacy & Security → Accessibility to focus windows and perform requested clicks or scrolling. Then retry the action.") }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovering = hovering
            }
            if hovering {
                controller.wakeIfSleeping()
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: controller.petState.patReactionCount)
    }

    /// Kept content is independent of speech and completed tool-call expiration.
    @ViewBuilder
    private var presentationEntries: some View {
        let dialogs = controller.appState?.agentPrompts.dialogs.filter { $0.isPetPresentation && !$0.usesPetCaption } ?? []
        if !dialogs.isEmpty || !controller.presentation.images.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(dialogs) { dialog in
                        PetPresentationEntry(title: dialog.title ?? "Interactive View", symbol: "rectangle.and.hand.point.up.left",
                            isExpanded: controller.presentation.expandedID == dialog.id,
                            toggle: { togglePresentation(dialog.id) },
                            remove: { controller.appState?.removeAgentUIView(id: dialog.id) })
                    }
                    ForEach(controller.presentation.images) { image in
                        PetPresentationEntry(title: image.title, symbol: "photo",
                            isExpanded: controller.presentation.expandedID == image.id,
                            toggle: { togglePresentation(image.id) },
                            remove: { controller.presentation.removeImage(image.id) })
                    }
                }.padding(4)
            }
            .scrollIndicators(.hidden)
            .frame(width: 240, height: 44)
        }
    }

    private func togglePresentation(_ id: UUID) {
        controller.presentation.expand(id)
    }

    private var pendingConfirmation: AgentConfirmation? {
        controller.appState?.agentPrompts.confirmations.first {
            $0.sessionKey.hasPrefix("pet-") && !$0.isMinimized
        }
    }

    // MARK: - Bubble Content

    private var activeBubbleText: String? {
        if let overlay = controller.actionStatusOverlayMessage, !overlay.isEmpty {
            return overlay
        }
        if !controller.livePartialUserText.isEmpty {
            return "“\(controller.livePartialUserText)”"
        }
        return controller.petState.bubble?.text
    }

    @ViewBuilder
    private func speechBubbleView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    if controller.actionStatusOverlayMessage != nil || controller.activeToolDescription != nil {
                        PetLoadingSpinner()
                            .transition(.opacity)
                    } else {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 6, height: 6)
                            .transition(.opacity)
                    }
                }
                .frame(width: 14, height: 14)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: controller.activeToolDescription != nil)

                Text(bubbleHeaderTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if controller.petState.bubble != nil && controller.actionStatusOverlayMessage == nil {
                    Button {
                        controller.dismissBubble()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss bubble")
                }
            }

            ScrollView(.vertical) {
                MarkdownContentView(text: text, style: .rxCodeCompact)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        ceil(geometry.size.height)
                    } action: { height in
                        captionTextHeight = height
                    }
            }
            .frame(height: min(max(1, captionTextHeight), 240))
            .scrollBounceBehavior(.basedOnSize)

            if let action = controller.petState.bubble?.action,
               controller.actionStatusOverlayMessage == nil {
                Button {
                    controller.performQuickAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 236, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
        )
    }

    private var bubbleHeaderTitle: String {
        if controller.actionStatusOverlayMessage != nil {
            return "Setting Up"
        }
        if controller.activeToolDescription != nil {
            return "Working"
        }
        if !controller.livePartialUserText.isEmpty {
            return "Listening"
        }
        return controller.petState.bubble?.title ?? controller.character.displayName
    }

    private var statusDotColor: Color {
        switch controller.petState.status {
        case .listening, .userSpeaking: .cyan
        case .thinking, .working: .orange
        case .speaking, .celebrating: .green
        case .failed: .red
        case .idle, .sleeping: .secondary
        }
    }

    // MARK: - Quick Controls Pill

    private var quickControlsBar: some View {
        HStack(spacing: 8) {
            // Toggle Live Voice
            Button {
                controller.toggleVoice()
            } label: {
                Image(systemName: controller.isVoiceActive ? "phone.down.fill" : "phone.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(controller.isVoiceActive ? .white : .primary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(controller.isVoiceActive ? Color.red : Color.accentColor.opacity(0.2))
                    )
            }
            .buttonStyle(.plain)
            .help(controller.isVoiceActive ? "End Voice Mode" : "Start Voice Mode (\(controller.configuration.voiceMode.shortTitle))")

            Button {
                controller.toggleMute()
            } label: {
                Image(systemName: controller.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(controller.isMuted ? .orange : .cyan)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(controller.isMuted ? "Unmute Microphone" : "Mute Microphone (keep conversation connected)")
            .accessibilityLabel(controller.isMuted ? "Unmute Microphone" : "Mute Microphone")

            if controller.petState.status == .speaking || controller.isStandaloneSpeaking {
                Button {
                    controller.interruptSpeaking()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Interrupt Speech")
            }

            Button {
                Task { await controller.triggerDailyReport(speakAloud: true, openSheet: false) }
            } label: {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(controller.isGeneratingDailyReport)
            .help("Speak Daily Report")

            Button {
                controller.openCompanionWindow()
            } label: {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Open Pet Companion")

            Button {
                controller.openSettingsWindow()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Pet & Voice Settings")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
        )
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var petContextMenu: some View {
        if let confirmation = controller.appState?.agentPrompts.confirmations.first(where: {
            $0.isFromPetCompanion && $0.isMinimized
        }) {
            Button("Review Pending Confirmation") {
                controller.appState?.setAgentConfirmationMinimized(id: confirmation.id, minimized: false)
            }
            Divider()
        }
        Button {
            controller.toggleVoice()
        } label: {
            Label(
                controller.isVoiceActive ? "Stop Voice Mode" : "Start Voice Mode",
                systemImage: controller.isVoiceActive ? "phone.down.fill" : "phone.fill"
            )
        }

        Button {
            controller.toggleMute()
        } label: {
            Label(controller.isMuted ? "Unmute Microphone" : "Mute Microphone", systemImage: controller.isMuted ? "mic.slash.fill" : "mic.fill")
        }

        Menu("Voice Mode") {
            ForEach(PetVoiceModeKind.allCases) { mode in
                Button {
                    controller.configuration.voiceMode = mode
                } label: {
                    HStack {
                        Text(mode.title)
                        if controller.configuration.voiceMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Divider()

        Button {
            Task { await controller.triggerDailyReport(speakAloud: true, openSheet: true) }
        } label: {
            Label("Daily Workspace Report…", systemImage: "doc.text.magnifyingglass")
        }

        Button {
            controller.openCompanionWindow()
        } label: {
            Label("Open Pet Companion", systemImage: "waveform.and.mic")
        }

        Button {
            controller.openSettingsWindow(tab: .looks)
        } label: {
            Label("Customize Look…", systemImage: "paintpalette")
        }

        Button {
            controller.openSettingsWindow(tab: .voices)
        } label: {
            Label("Manage Voices…", systemImage: "person.wave.2")
        }

        Button {
            controller.openSettingsWindow()
        } label: {
            Label("Pet & Voice Settings…", systemImage: "gearshape")
        }

        Divider()

        Button(role: .destructive) {
            controller.setPetEnabled(false)
        } label: {
            Label("Hide Desktop Pet", systemImage: "eye.slash")
        }
    }
}

/// Keep meter observation below the overlay so audio does not remeasure captions or resize panels.
private struct PetVoiceSprite: View {
    let controller: PetController

    var body: some View {
        PetSpriteView(
            character: controller.character,
            state: controller.petState,
            inputLevel: controller.inputLevel,
            speechPlayback: controller.speechPlayback,
            size: CGFloat(controller.configuration.petSize),
            isVoiceActive: controller.isVoiceActive || controller.isStandaloneSpeaking,
            isAnimationActive: controller.configuration.isEnabled
        )
    }
}
