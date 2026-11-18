import AppKit
import ImageIO
import SwiftUI
import os

let petAnimationLogger = Logger(subsystem: "com.claudework", category: "PetAnimation")

// MARK: - Sprite Cache

final class PetSpriteCache: @unchecked Sendable {
    static let shared = PetSpriteCache()

    struct DecodedAtlas: Sendable {
        let manifest: PetAnimationManifest
        /// Indexed `[row][col]` where `row` in `0..<rows` and `col` in `0..<columns`.
        let frames: [[CGImage]]
        let closedFrames: [[CGImage]]
        let openFrames: [[CGImage]]
        let expressions: [CGImage]
    }

    private let lock = NSLock()
    private var cache: [String: DecodedAtlas] = [:]

    func atlas(for character: PetCharacter) -> DecodedAtlas? {
        lock.lock()
        if let existing = cache[character.id] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        if !character.additionalSpriteSheetURLs.isEmpty, let first = character.spriteSheetURL {
            let urls = [first] + character.additionalSpriteSheetURLs
            var pages: [DecodedAtlas] = []
            for (index, url) in urls.enumerated() {
                var page = PetCharacter(id: "\(character.id)-page-\(index)", displayName: character.displayName,
                    spriteSheetURL: url, expressionsURL: nil, animationManifestURL: index == 0 ? character.animationManifestURL
                        : (FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("json").path)
                           ? url.deletingPathExtension().appendingPathExtension("json") : nil),
                    frameColumns: character.frameColumns, frameRows: character.frameRows, overlaysExpressions: false)
                page.spriteFrameDuration = character.spriteFrameDuration
                page.speechMouth = character.speechMouth
                if index < character.closedMouthSheetURLs.count { page.closedMouthSheetURLs = [character.closedMouthSheetURLs[index]] }
                if index < character.openMouthSheetURLs.count { page.openMouthSheetURLs = [character.openMouthSheetURLs[index]] }
                guard let atlas = atlas(for: page) else { return nil }
                pages.append(atlas)
            }
            let frames = (0..<character.frameRows).map { row in pages.flatMap { $0.frames[row] } }
            let specs = (0..<character.frameRows).flatMap { row in pages.flatMap { page in
                Array(page.manifest.frames.dropFirst(row * character.frameColumns).prefix(character.frameColumns))
            } }
            let decoded = DecodedAtlas(manifest: PetAnimationManifest(version: 1,
                frameWidth: pages[0].manifest.frameWidth, frameHeight: pages[0].manifest.frameHeight, frames: specs),
                frames: frames,
                closedFrames: (0..<character.frameRows).map { row in pages.flatMap { $0.closedFrames[row] } },
                openFrames: (0..<character.frameRows).map { row in pages.flatMap { $0.openFrames[row] } },
                expressions: [])
            lock.lock()
            cache[character.id] = decoded
            lock.unlock()
            return decoded
        }

        guard let sheetURL = character.spriteSheetURL,
              let sheetImage = Self.loadCGImage(from: sheetURL) else {
            return nil
        }

        let manifest: PetAnimationManifest
        if let manifestURL = character.animationManifestURL,
           let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(PetAnimationManifest.self, from: data) {
            manifest = decoded
        } else {
            let fw = max(1, sheetImage.width / max(1, character.frameColumns))
            let fh = max(1, sheetImage.height / max(1, character.frameRows))
            var specs: [PetAnimationManifest.FrameSpec] = []
            for r in 0..<character.frameRows {
                for c in 0..<character.frameColumns {
                    specs.append(.init(
                        x: c * fw,
                        y: r * fh,
                        width: fw,
                        height: fh,
                        faceX: Double(fw) * 0.5,
                        faceY: Double(fh) * 0.42,
                        faceSize: Double(fw) * 0.4,
                        duration: character.spriteFrameDuration ?? 0.16
                    ))
                }
            }
            manifest = PetAnimationManifest(version: 1, frameWidth: fw, frameHeight: fh, frames: specs)
        }

        let cols = max(1, character.frameColumns)
        let rows = max(1, character.frameRows)
        var grid: [[CGImage]] = Array(repeating: [], count: rows)
        var closedGrid = grid
        var openGrid = grid
        let closedSheet = character.closedMouthSheetURLs.first.flatMap(Self.loadCGImage)
        let openSheet = character.openMouthSheetURLs.first.flatMap(Self.loadCGImage)

        for row in 0..<rows {
            var rowImages: [CGImage] = []
            for col in 0..<cols {
                let index = row * cols + col
                let cropRect: CGRect
                if character.animationManifestURL != nil, index < manifest.frames.count {
                    let spec = manifest.frames[index]
                    cropRect = CGRect(x: spec.x, y: spec.y, width: spec.width, height: spec.height)
                } else {
                    let cw = Double(sheetImage.width) / Double(cols)
                    let ch = Double(sheetImage.height) / Double(rows)
                    cropRect = CGRect(x: Double(col) * cw, y: Double(row) * ch, width: cw, height: ch)
                }
                if let cropped = sheetImage.cropping(to: cropRect) {
                    rowImages.append(cropped)
                    let spec = manifest.frames[index]
                    let mouth = PetSpeechFrames.mouth(for: cropped, spec: spec, normalized: character.speechMouth)
                    let electronic = character.id.hasPrefix("rxcode-buddy")
                    closedGrid[row].append(closedSheet?.cropping(to: cropRect)
                        ?? PetSpeechFrames.bake(cropped, mouth: mouth, open: false, electronic: electronic))
                    openGrid[row].append(openSheet?.cropping(to: cropRect)
                        ?? PetSpeechFrames.bake(cropped, mouth: mouth, open: true, electronic: electronic))
                }
            }
            grid[row] = rowImages
        }

        var expressions: [CGImage] = []
        if let exprURL = character.expressionsURL,
           let exprSheet = Self.loadCGImage(from: exprURL) {
            let count = 6
            let cellW = max(1, exprSheet.width / count)
            let cellH = exprSheet.height
            for i in 0..<count {
                let rect = CGRect(x: i * cellW, y: 0, width: cellW, height: cellH)
                if let cropped = exprSheet.cropping(to: rect) {
                    expressions.append(cropped)
                }
            }
        }

        let decoded = DecodedAtlas(manifest: manifest, frames: grid, closedFrames: closedGrid, openFrames: openGrid, expressions: expressions)
        lock.lock()
        cache[character.id] = decoded
        lock.unlock()
        return decoded
    }

    func frameDurations(for character: PetCharacter, motion: PetMotion) -> [TimeInterval] {
        guard let atlas = atlas(for: character) else { return [] }
        let row = min(max(0, motion.rowIndex), atlas.frames.count - 1)
        let rowFrames = atlas.frames[row]

        let cols = rowFrames.count
        var durations: [TimeInterval] = []
        durations.reserveCapacity(rowFrames.count)
        for col in 0..<rowFrames.count {
            let idx = row * cols + col
            let d = (idx < atlas.manifest.frames.count ? atlas.manifest.frames[idx].duration : nil)
                ?? motion.defaultFrameDuration
            durations.append(max(0.04, d))
        }
        return durations
    }

    func animationDuration(for character: PetCharacter, motion: PetMotion) -> TimeInterval {
        frameDurations(for: character, motion: motion).reduce(0, +)
    }

    /// Frame durations for every idle-choreography pose this character actually has a row for.
    func idleRows(for character: PetCharacter) -> [PetMotion: [TimeInterval]] {
        guard let atlas = atlas(for: character) else { return [:] }
        var rows: [PetMotion: [TimeInterval]] = [:]
        for motion in PetIdleChoreographer.candidateMotions
        where motion.rowIndex < atlas.frames.count && !atlas.frames[motion.rowIndex].isEmpty {
            rows[motion] = frameDurations(for: character, motion: motion)
        }
        return rows
    }

    func frameIndex(for character: PetCharacter, motion: PetMotion, at elapsed: TimeInterval, looping: Bool = false) -> Int {
        let durations = frameDurations(for: character, motion: motion)
        guard !durations.isEmpty else { return 0 }
        // Reactions settle; ongoing speech keeps cycling through body poses.
        var cursor = max(0, elapsed)
        if looping {
            cursor = cursor.truncatingRemainder(dividingBy: durations.reduce(0, +))
        }
        for (i, d) in durations.enumerated() {
            if cursor < d { return i }
            cursor -= d
        }
        return durations.count - 1
    }

    private static func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Animated Pet Sprite View

struct PetSpriteView: View {
    let character: PetCharacter
    let state: PetState
    var inputLevel: Float = 0
    var outputLevel: Float = 0
    var speechPlayback: PetSpeechPlaybackSignal?
    var size: CGFloat = 112
    var isVoiceActive: Bool = false
    var isAnimationActive: Bool = true
    var previewFrameIndex: Int? = nil
    var previewMouthOpen: Bool? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScreenAwake = true
    @State private var gesture: PetGesture?
    @State private var previousGesture: PetGesture?
    @State private var anchorDate = Date.now
    @State private var bounceScale: CGFloat = 1.0
    @State private var bodyVolumeStep = 0
    @State private var showPatSparkle = false
    @State private var idleScript = PetIdleScript()

    var body: some View {
        let motion = gesture?.motion ?? state.resolvedMotion
        let activeLevel = CGFloat(max(inputLevel, outputLevel))
        let volumeStep = Int((min(1, max(0, activeLevel)) * 4).rounded())

        ZStack {
            // Subtle voice aura ring when voice mode is active
            if isVoiceActive {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                auraColor.opacity(0.32 + Double(activeLevel) * 0.38),
                                auraColor.opacity(0.08),
                                .clear,
                            ],
                            center: .center,
                            startRadius: size * 0.14,
                            endRadius: size * (0.52 + activeLevel * 0.16)
                        )
                    )
                    .frame(width: size * 1.2, height: size * 1.2)
                    .animation(.easeOut(duration: 0.12), value: activeLevel)
            }

            if reduceMotion || !isAnimationActive || !isScreenAwake || scenePhase == .background {
                spriteFrameView(motion: motion, elapsed: 0)
            } else if isSpeaking {
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(anchorDate))
                    let phase = elapsed * .pi * 2
                    let level = CGFloat(speechPlayback?.envelope.level() ?? outputLevel)
                    let strength = 0.55 + min(1, max(0, level)) * 0.45
                    let bob = (1 - cos(phase * 1.8)) / 2
                    gestureFrameView(motion: motion, elapsed: elapsed)
                        .scaleEffect(x: 1 - bob * 0.006 * strength,
                                     y: 1 + bob * 0.012 * strength, anchor: .bottom)
                        .rotationEffect(.degrees(sin(phase * 0.65) * 1.2 * Double(strength)), anchor: .bottom)
                        .offset(y: -size * 0.018 * bob * strength)
                }
            } else if let sleepy = ambientIdleSleepy {
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(anchorDate))
                    let step = idleScript.step(
                        at: elapsed,
                        key: "\(character.id)|\(sleepy)|\(anchorDate.timeIntervalSinceReferenceDate)",
                        sleepy: sleepy,
                        rows: { PetSpriteCache.shared.idleRows(for: character) })
                    // Breathing never stops, so even pauses between bouts stay alive.
                    let breath = (1 - cos(elapsed * 2 * .pi / (sleepy ? 4.6 : 3.2))) / 2
                    spriteFrameView(motion: step?.motion ?? .idle, elapsed: 0, column: step?.column)
                        .scaleEffect(x: 1 - breath * 0.008, y: 1 + breath * 0.018, anchor: .bottom)
                }
            } else if state.isWalking || (gesture == nil && (motion == .idle || (!character.additionalSpriteSheetURLs.isEmpty
                && [.working, .waiting, .resting].contains(motion)))) {
                let loopMotion: PetMotion = state.isWalking ? .walking : motion
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                    let duration = max(0.1, PetSpriteCache.shared.animationDuration(for: character, motion: loopMotion))
                    let elapsed = max(0, context.date.timeIntervalSince(anchorDate)).truncatingRemainder(dividingBy: duration)
                    spriteFrameView(motion: loopMotion, elapsed: elapsed)
                }
            } else {
                TimelineView(.explicit(playbackDates(for: motion))) { context in
                    let elapsed = context.date.timeIntervalSince(anchorDate)
                    gestureFrameView(motion: motion, elapsed: elapsed)
                }
            }

            if showPatSparkle {
                Image(systemName: "heart.fill")
                    .font(.system(size: max(14, size * 0.17), weight: .bold))
                    .foregroundStyle(Color.pink.gradient)
                    .shadow(color: .pink.opacity(0.45), radius: 4, y: 1)
                    .offset(x: size * 0.28, y: -size * 0.36)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .hueRotation(.degrees(character.lookHue))
        .saturation(character.lookSaturation)
        .overlay(alignment: .topTrailing) {
            if character.lookAccessory != "none" {
                Image(systemName: character.lookAccessory == "crown" ? "crown.fill" : character.lookAccessory == "heart" ? "heart.fill" : "star.fill")
                    .font(.system(size: size * 0.22))
                    .foregroundStyle(character.lookAccessory == "heart" ? Color.pink : Color.yellow)
                    .shadow(radius: 2)
                    .accessibilityLabel(character.lookAccessory)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(bounceScale * (1.0 + CGFloat(bodyVolumeStep) / 4 * 0.045))
        .task(id: volumeStep) {
            guard volumeStep != bodyVolumeStep else { return }
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                bodyVolumeStep = volumeStep
            }
        }
        .onChange(of: animationDebugSummary, initial: true) { _, summary in
            petAnimationLogger.debug("[\(character.id, privacy: .public)] size=\(Int(size)) \(summary, privacy: .public)")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            isScreenAwake = false
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
            isScreenAwake = true
        }
        .task(id: animationKey) {
            gesture = nil
            guard animationKey.enabled else { return }
            do {
                // Let a status transition finish before starting ambient gestures.
                try await Task.sleep(for: .seconds(max(2, PetSpriteCache.shared.animationDuration(
                    for: character, motion: state.resolvedMotion))))
                while !Task.isCancelled {
                    try Task.checkCancellation()
                    guard let next = PetGesture.choices(for: animationKey.status, excluding: previousGesture).randomElement() else { return }
                    previousGesture = next
                    anchorDate = .now
                    gesture = next
                    let duration = max(next.duration, PetSpriteCache.shared.animationDuration(for: character, motion: next.motion))
                    try await Task.sleep(for: .seconds(duration))
                    try Task.checkCancellation()
                    gesture = nil
                    try await Task.sleep(for: .seconds(Double.random(in: PetGesture.restRange(for: animationKey.status))))
                }
            } catch {
                // SwiftUI cancels this task when hidden, removed, or its state changes.
            }
        }
        .onChange(of: gesture) { _, next in
            if next == nil {
                // Resume ongoing animation; other statuses rest in their settled pose.
                anchorDate = state.resolvedMotion == .idle || isSpeaking ? .now : Date.now.addingTimeInterval(
                    -PetSpriteCache.shared.animationDuration(for: character, motion: state.resolvedMotion))
            }
        }
        .onChange(of: state.resolvedMotion) { _, _ in
            anchorDate = .now
        }
        .onChange(of: isSpeaking) { _, _ in
            anchorDate = .now
        }
        .onChange(of: character.id) { _, _ in
            anchorDate = .now
        }
        .onChange(of: state.patReactionCount) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.45)) {
                bounceScale = 1.12
                showPatSparkle = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                    bounceScale = 1.0
                }
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeOut(duration: 0.25)) {
                    showPatSparkle = false
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(character.displayName), \(state.status.label)")
    }

    private struct AnimationKey: Equatable {
        let status: PetStatus
        let motion: PetMotion
        let characterID: String
        let enabled: Bool
    }

    private var animationKey: AnimationKey {
        AnimationKey(status: isSpeaking ? .speaking : state.status, motion: state.resolvedMotion, characterID: character.id,
                     enabled: isAnimationActive && isScreenAwake && !reduceMotion && scenePhase != .background
                        && (isSpeaking || state.resolvedMotion != .idle)
                        && state.motion == .automatic && !state.isWalking
                        && !PetGesture.choices(for: isSpeaking ? .speaking : state.status, excluding: nil).isEmpty)
    }

    /// Which rendering branch `body` takes and every input that decides it, for debugging stuck animation.
    private var animationDebugSummary: String {
        let motion = gesture?.motion ?? state.resolvedMotion
        let branch: String
        if reduceMotion || !isAnimationActive || !isScreenAwake || scenePhase == .background {
            branch = "STATIC(no animation)"
        } else if isSpeaking {
            branch = "speaking"
        } else if let sleepy = ambientIdleSleepy {
            branch = sleepy ? "ambient-idle(sleepy)" : "ambient-idle"
        } else if state.isWalking || (gesture == nil && (motion == .idle || (!character.additionalSpriteSheetURLs.isEmpty
            && [.working, .waiting, .resting].contains(motion)))) {
            branch = "loop(\(motion.rawValue))"
        } else {
            branch = "one-shot(\(motion.rawValue))"
        }
        let atlas = PetSpriteCache.shared.atlas(for: character)
        let rows = atlas.map { "\($0.frames.count)x\($0.frames.first?.count ?? 0)" } ?? "nil"
        return "branch=\(branch) reduceMotion=\(reduceMotion) isAnimationActive=\(isAnimationActive) "
            + "screenAwake=\(isScreenAwake) scenePhase=\(scenePhase) status=\(state.status) mood=\(state.mood) "
            + "motion=\(state.motion.rawValue) resolved=\(state.resolvedMotion.rawValue) walking=\(state.isWalking) "
            + "gesture=\(gesture.map { "\($0)" } ?? "nil") speaking=\(isSpeaking) "
            + "speechSignalActive=\(speechPlayback.map { "\($0.isActive)" } ?? "nil") preview=\(previewFrameIndex.map(String.init) ?? "nil") "
            + "atlas=\(rows) idleRows=\(PetSpriteCache.shared.idleRows(for: character).keys.map(\.rawValue).sorted())"
    }

    /// Non-nil while the pet is ambient (idle or asleep); the value says whether to use the drowsy routine.
    private var ambientIdleSleepy: Bool? {
        guard gesture == nil, !isSpeaking, !state.isWalking, state.motion == .automatic else { return nil }
        switch state.status {
        case .idle: return state.mood == .sleepy
        case .sleeping: return true
        default: return nil
        }
    }

    private var isSpeaking: Bool {
        speechPlayback?.isActive ?? (state.status == .speaking)
    }

    private func gestureFrameView(motion: PetMotion, elapsed: TimeInterval) -> some View {
        let pose = gesture?.pose(at: elapsed) ?? PetGesture.Pose()
        return spriteFrameView(motion: motion, elapsed: elapsed)
            .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
            .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
            .offset(x: size * pose.x, y: size * pose.y)
    }

    @ViewBuilder
    private func spriteFrameView(motion: PetMotion, elapsed: TimeInterval, column: Int? = nil) -> some View {
        if let atlas = PetSpriteCache.shared.atlas(for: character),
           motion.rowIndex < atlas.frames.count,
           !atlas.frames[motion.rowIndex].isEmpty {
            let col = min(max(0, previewFrameIndex ?? column ?? PetSpriteCache.shared.frameIndex(
                for: character, motion: motion, at: elapsed, looping: isSpeaking && gesture == nil)), atlas.frames[motion.rowIndex].count - 1)
            let frameImage = atlas.frames[motion.rowIndex][col]

            ZStack {
                PetSpeechFrameView(resting: frameImage, closed: atlas.closedFrames[motion.rowIndex][col],
                                   open: atlas.openFrames[motion.rowIndex][col], signal: speechPlayback,
                                   previewOpen: previewMouthOpen)
                    .frame(width: size, height: size)
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)


                if character.overlaysExpressions,
                   state.resolvedMood.expressionColumn < atlas.expressions.count {
                    let expr = atlas.expressions[state.resolvedMood.expressionColumn]
                    Image(decorative: expr, scale: 1.0)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.38, height: size * 0.24)
                        .offset(y: -size * 0.09)
                }

            }
        } else {
            fallbackMascotView
        }
    }

    private func playbackDates(for motion: PetMotion) -> [Date] {
        let duration = max(gesture?.duration ?? 0, PetSpriteCache.shared.animationDuration(for: character, motion: motion))
        // A finite schedule stops requesting redraws after the animation settles.
        let ticks = Int(ceil(duration * 24))
        return (0...ticks).map { anchorDate.addingTimeInterval(Double($0) / 24) }
    }

    private var fallbackMascotView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.96, green: 0.94, blue: 0.89), Color(red: 0.85, green: 0.83, blue: 0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: size * 0.76, height: size * 0.72)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(Color(red: 0.09, green: 0.12, blue: 0.18))
                .frame(width: size * 0.56, height: size * 0.36)

            Image(systemName: isVoiceActive ? "waveform" : "sparkles")
                .font(.system(size: size * 0.22, weight: .bold))
                .foregroundStyle(.cyan)

        }
    }

    private var auraColor: Color {
        switch state.status {
        case .listening: .cyan
        case .userSpeaking: .mint
        case .thinking, .working: .orange
        case .speaking: .blue
        case .celebrating: .green
        case .failed: .red
        case .idle, .sleeping: .teal
        }
    }
}

/// Only this leaf observes the audio clock; body animation and panel layout stay independent.
private struct PetSpeechFrameView: View {
    let resting: CGImage
    let closed: CGImage
    let open: CGImage
    var signal: PetSpeechPlaybackSignal?
    var previewOpen: Bool?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: signal?.isActive != true || previewOpen != nil)) { _ in
            let frame = previewOpen.map { $0 ? open : closed }
                ?? (signal?.isActive == true ? (signal?.envelope.isMouthOpen() == true ? open : closed) : resting)
            Image(decorative: frame, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }
}
