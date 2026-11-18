import AppKit
import Combine
import MusicKit
import Observation
import RxCodeCore

@MainActor
protocol PetMusicPlaying: AnyObject {
    var isPlaying: Bool { get }
    var stateDescription: String { get }
    var title: String? { get }
    var artist: String? { get }
    var artwork: Artwork? { get }
    var hasCurrentEntry: Bool { get }
    func observe(_ change: @escaping @MainActor () -> Void) -> [AnyCancellable]
    func queue(_ song: Song)
    func clear()
    func play() async throws
    func pause()
    func stop()
}

@MainActor
final class PetNativeMusicPlayer: PetMusicPlaying {
    private let player = ApplicationMusicPlayer.shared
    var isPlaying: Bool { player.state.playbackStatus == .playing }
    var stateDescription: String { String(describing: player.state.playbackStatus) }
    var title: String? { player.queue.currentEntry?.title }
    var artist: String? { player.queue.currentEntry?.subtitle }
    var artwork: Artwork? { player.queue.currentEntry?.artwork }
    var hasCurrentEntry: Bool { player.queue.currentEntry != nil }
    func observe(_ change: @escaping @MainActor () -> Void) -> [AnyCancellable] {
        [player.state.objectWillChange.sink { _ in Task { @MainActor in change() } },
         player.queue.objectWillChange.sink { _ in Task { @MainActor in change() } }]
    }
    func queue(_ song: Song) { player.queue = ApplicationMusicPlayer.Queue(for: [song]) }
    func clear() { player.queue = [] }
    func play() async throws { try await player.play() }
    func pause() { player.pause() }
    func stop() { player.stop() }
}

/// An application-scoped player owns only the pet's queue. It never pauses/stops Music.app.
@MainActor @Observable
final class PetMusic {
    private unowned let controller: PetController
    private let player: any PetMusicPlaying
    private let volumeController: any PetMusicVolumeControlling
    var volume = PetMusicVolumeState()
    var volumeError: String?
    @ObservationIgnored private let requestAuthorization: @Sendable () async -> Bool
    @ObservationIgnored private let currentAuthorizationStatus: @Sendable () -> MusicAuthorization.Status
    @ObservationIgnored private let checkConnection: @Sendable () async throws -> Bool
    @ObservationIgnored private var observations: [AnyCancellable] = []
    @ObservationIgnored private var operation: Task<JSONValue, Error>?
    @ObservationIgnored private var connectionCheck: Task<Void, Never>?
    @ObservationIgnored private var connectionRevision = UUID()
    var isCheckingConnection = false
    var connectionError: String?
    private var generation = UUID()
    private var songs: [String: Song] = [:]
    var isLinked = false
    var canPlayCatalogContent: Bool?
    var authorizationStatus: MusicAuthorization.Status
    var enabled = false
    var isBusy = false
    /// True only while an agent-requested play/resume is loading, so the card can show progress.
    var isLoadingPlayback = false
    var isTurningOff = false
    var ownsQueue = false
    var title = "No song selected"
    var artist = ""
    var artwork: Artwork?
    var isPlaying = false
    var playbackState = "stopped"
    var errorMessage: String?

    init(controller: PetController, player: (any PetMusicPlaying)? = nil,
         volumeController: (any PetMusicVolumeControlling)? = nil,
         currentAuthorizationStatus: @escaping @Sendable () -> MusicAuthorization.Status = { MusicAuthorization.currentStatus },
         requestAuthorization: @escaping @Sendable () async -> Bool = {
             // Same flow as LyricStudio: only prompt while undetermined; re-requesting after a
             // denial never shows UI and just reports the stored decision.
             var status = MusicAuthorization.currentStatus
             if status == .notDetermined { status = await MusicAuthorization.request() }
             return status == .authorized
         },
         checkConnection: @escaping @Sendable () async throws -> Bool = {
             // Subscription state comes from the account signed in to Music. A one-result catalog
             // search proves the automatic developer token works without needing a user token
             // (the previous /v1/me/storefront call failed whenever the user-token fetch did).
             let playable = try await MusicSubscription.current.canPlayCatalogContent
             var probe = MusicCatalogSearchRequest(term: "music", types: [Song.self])
             probe.limit = 1
             _ = try await probe.response()
             return playable
         }) {
        self.controller = controller
        self.checkConnection = checkConnection
        self.requestAuthorization = requestAuthorization
        self.currentAuthorizationStatus = currentAuthorizationStatus
        self.authorizationStatus = currentAuthorizationStatus()
        self.player = player ?? PetNativeMusicPlayer()
        self.volumeController = volumeController ?? PetDeviceMusicVolume()
        observations = self.player.observe { [weak self] in self?.synchronize() }
        observations.append(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in await self?.refreshConnection() } })
    }

    /// Refreshing never requests authorization, changes the Off preference, or starts playback.
    /// All lifecycle, settings and tool callers join the same account check.
    func refreshConnection() async {
        authorizationStatus = currentAuthorizationStatus()
        guard authorizationStatus == .authorized else {
            connectionRevision = UUID()
            connectionCheck?.cancel()
            connectionCheck = nil
            isCheckingConnection = false
            isLinked = false
            canPlayCatalogContent = nil
            connectionError = nil
            return
        }
        if let connectionCheck { await connectionCheck.value; return }
        let revision = UUID()
        connectionRevision = revision
        isCheckingConnection = true
        connectionError = nil
        // An old subscription result is not evidence of current account availability.
        isLinked = false
        canPlayCatalogContent = nil
        let check = checkConnection
        let task = Task { [weak self] in
            do {
                let playable = try await check()
                guard let self, self.connectionRevision == revision else { return }
                self.authorizationStatus = self.currentAuthorizationStatus()
                self.isLinked = self.authorizationStatus == .authorized
                self.canPlayCatalogContent = self.isLinked ? playable : nil
            } catch {
                guard let self, self.connectionRevision == revision else { return }
                self.authorizationStatus = self.currentAuthorizationStatus()
                self.isLinked = false
                self.canPlayCatalogContent = nil
                if self.authorizationStatus == .authorized {
                    self.connectionError = "Account availability could not be verified. " + Self.describe(error)
                }
            }
            guard let self, self.connectionRevision == revision else { return }
            self.isCheckingConnection = false
            self.connectionCheck = nil
        }
        connectionCheck = task
        await task.value
    }

    func refreshConnectionInBackground() {
        Task { [weak self] in await self?.refreshConnection() }
    }

    func synchronize() {
        isPlaying = player.isPlaying
        playbackState = player.stateDescription
        title = player.title ?? "No song selected"
        artist = player.artist ?? ""
        artwork = player.artwork
    }

    /// The now-playing card exists only for agent-requested playback; idle music shows nothing.
    var showsPlayer: Bool { enabled && (ownsQueue || isLoadingPlayback) }

    func off() async -> JSONValue {
        guard !isTurningOff else { return result() }
        isTurningOff = true
        generation = UUID()
        let pending = operation
        pending?.cancel()
        enabled = false
        isLoadingPlayback = false
        if ownsQueue { player.stop() }
        _ = try? await pending?.value
        // A cancelled asynchronous play() can still finish after stop(). Stop again before
        // allowing a new command; no unrelated Music.app playback is owned by this player.
        if ownsQueue { player.stop(); player.clear() }
        ownsQueue = false
        operation = nil
        isBusy = false
        isTurningOff = false
        errorMessage = nil
        synchronize()
        controller.panelController.updatePanelLayout()
        return result()
    }

    func handle(_ arguments: JSONValue) async throws -> JSONValue {
        let action = arguments["action"]?.stringValue ?? "status"
        if ["volume", "set_volume", "increase_volume", "decrease_volume"].contains(action) {
            return try handleVolume(action, arguments: arguments)
        }
        if action == "off" { return await off() }
        if action == "status" {
            refreshVolume()
            await refreshConnection()
            synchronize()
            return result()
        }
        guard !isTurningOff, !isBusy else { throw IDEToolError.handlerFailed("A music command is still in progress. Wait or turn music off.") }
        guard ["connect", "enable", "search", "play", "resume", "pause"].contains(action) else { throw IDEToolError.invalidArguments("Unknown music action.") }
        guard action == "connect" || controller.configuration.isEnabled else { throw IDEToolError.handlerFailed("Enable the desktop pet before using pet music.") }
        if action != "connect" {
            enabled = true
            controller.panelController.show()
        }
        if action == "enable" { return result() }
        if action == "pause" {
            if ownsQueue { player.pause() }
            synchronize()
            return result()
        }
        let token = UUID()
        generation = token
        isBusy = true
        isLoadingPlayback = action == "play" || action == "resume"
        errorMessage = nil
        controller.panelController.updatePanelLayout()
        let task = Task { try await self.perform(action, arguments: arguments, token: token) }
        operation = task
        return try await withTaskCancellationHandler {
            defer {
                if generation == token { operation = nil; isBusy = false; isLoadingPlayback = false }
                controller.panelController.updatePanelLayout()
            }
            do { return try await task.value }
            catch is CancellationError {
                if action != "connect", generation == token, ownsQueue { player.stop(); synchronize() }
                throw CancellationError()
            }
            catch {
                guard generation == token else { throw CancellationError() }
                if action == "connect" { isLinked = false; canPlayCatalogContent = nil }
                errorMessage = Self.describe(error)
                synchronize()
                throw IDEToolError.handlerFailed(errorMessage!)
            }
        } onCancel: { task.cancel() }
    }

    func refreshVolume() { volume = volumeController.read() }

    /// The slider and tool share hardware control and verify the actual level.
    @discardableResult
    func setVolume(_ level: Double, deviceID: UInt32?) -> Bool {
        volumeError = nil
        do {
            volume = try volumeController.set(level, deviceID: deviceID)
            guard let actual = volume.level, abs(actual - level) <= 1 else {
                volumeError = "The device has not confirmed the requested volume. The displayed level is its actual readback."
                return false
            }
            return true
        } catch {
            refreshVolume()
            volumeError = error.localizedDescription
            return false
        }
    }

    private func handleVolume(_ action: String, arguments: JSONValue) throws -> JSONValue {
        refreshVolume()
        volumeError = nil
        var applied: Bool?
        if action != "volume" {
            let field = action == "set_volume" ? "volume" : "amount"
            let value: Double
            if let supplied = arguments[field] {
                guard let number = supplied.numberValue, number.isFinite, (0...100).contains(number) else {
                    throw IDEToolError.invalidArguments("\(field) must be a finite number between 0 and 100 percent.")
                }
                value = number
            } else if action == "set_volume" {
                throw IDEToolError.invalidArguments("set_volume requires volume, from 0 to 100 percent.")
            } else { value = 5 }
            if let current = volume.level, volume.canSet {
                let target = action == "set_volume" ? value : min(100, max(0, current + (action == "increase_volume" ? value : -value)))
                applied = setVolume(target, deviceID: volume.deviceID)
            } else {
                applied = false
                volumeError = volume.unavailableReason ?? "Device volume control is unavailable."
            }
        }
        let level = volume.level.map { String(format: "%.1f%%", $0) } ?? "unavailable"
        let message = "Device output volume: \(level) on \(volume.deviceName). This affects all audio on the default output device, including pet music when routed there; it is not pet-only volume. Muted: \(volume.muted.map(String.init) ?? "unknown"). \(volumeError ?? volume.unavailableReason ?? "")"
        return .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(applied == false), "structuredContent": .object([
                "volume_scope": .string("default_output_device"), "volume": volume.level.map(JSONValue.number) ?? .null,
                "volume_settable": .bool(volume.canSet), "device": .string(volume.deviceName),
                "muted": volume.muted.map(JSONValue.bool) ?? .null,
                "applied": applied.map(JSONValue.bool) ?? .null,
                "error": volumeError.map(JSONValue.string) ?? .null
            ])])
    }

    private func perform(_ action: String, arguments: JSONValue, token: UUID) async throws -> JSONValue {
        let authorized = await requestAuthorization()
        authorizationStatus = currentAuthorizationStatus()
        guard authorized else {
            isLinked = false
            canPlayCatalogContent = nil
            throw IDEToolError.handlerFailed("Apple Music access is denied or restricted. No playback was started.")
        }
        if action == "connect" {
            try Task.checkCancellation()
            await refreshConnection()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if let connectionError { throw IDEToolError.handlerFailed(connectionError) }
            guard isLinked else { throw IDEToolError.handlerFailed("Apple Music authorization changed while checking the account.") }
            return result()
        }
        try check(token)
        if action == "resume" {
            guard ownsQueue, player.hasCurrentEntry else { throw IDEToolError.handlerFailed("No pet-owned song is queued. Search for and play a song first.") }
        } else {
            if let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                guard query.count <= 300 else { throw IDEToolError.invalidArguments("Music query is limited to 300 characters.") }
                var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
                request.limit = 8
                let response = try await request.response()
                try check(token)
                isLinked = true
                songs = Dictionary(uniqueKeysWithValues: response.songs.map { ($0.id.rawValue, $0) })
                if action == "search" { return searchResult(Array(response.songs)) }
                // Never silently choose one of several unrelated search matches.
                let exact = response.songs.filter { $0.title.localizedCaseInsensitiveCompare(query) == .orderedSame }
                guard response.songs.count == 1 || exact.count == 1 else { return searchResult(Array(response.songs)) }
                let song = exact.first ?? response.songs.first!
                songs[song.id.rawValue] = song
                try await begin(song, token: token)
                return result()
            }
            guard action != "search", let id = arguments["song_id"]?.stringValue, let song = songs[id] else {
                throw IDEToolError.invalidArguments("Search with query first, then play a song_id from those results (or use an unambiguous query).")
            }
            try await begin(song, token: token)
            return result()
        }
        try await player.play()
        try check(token)
        synchronize()
        return result()
    }

    private func begin(_ song: Song, token: UUID) async throws {
        let playable = try await MusicSubscription.current.canPlayCatalogContent
        try check(token)
        canPlayCatalogContent = playable
        guard playable else {
            throw IDEToolError.handlerFailed("This Apple Music account cannot play catalog content. Sign in to Music with an active Apple Music subscription.")
        }
        try check(token)
        player.queue(song)
        ownsQueue = true
        try await player.play()
        try check(token)
        synchronize()
    }

    /// Turns MusicKit failures into an actionable sentence instead of a generic Cocoa message.
    static func describe(_ error: Error) -> String {
        if let tool = error as? IDEToolError, let message = tool.errorDescription { return message }
        if let token = error as? MusicTokenRequestError {
            switch token {
            case .developerTokenRequestFailed:
                return "Apple Music rejected this build's developer token. MusicKit must be enabled for the app.rxlab.flowcy.code App ID, and the app must be signed by that team."
            case .permissionDenied:
                return "Apple Music access is denied. Allow RxCode in System Settings → Privacy & Security → Media & Apple Music."
            case .privacyAcknowledgementRequired:
                return "Open Music once and accept Apple Music's privacy notice, then link again."
            case .userNotSignedIn:
                return "No Apple Music account is signed in. Open Music and sign in, then link again."
            case .userTokenRequestFailed, .userTokenRevoked:
                return "Apple Music couldn't verify the signed-in account. Open Music, make sure you're signed in, then link again."
            case .unknown:
                return "Apple Music returned an unknown token error."
            @unknown default:
                return "Apple Music token error: \(token)."
            }
        }
        if let data = error as? MusicDataRequest.Error {
            return "Apple Music request failed (\(data.status) \(data.code)): \(data.title). \(data.detailText)"
        }
        let nsError = error as NSError
        return "Apple Music could not complete the request: \(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, enabled else { throw CancellationError() }
    }

    private func searchResult(_ matches: [Song]) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(matches.isEmpty ? "No matching catalog songs. No playback was started." : "Song candidates; choose song_id. Search alone did not start playback.\n" + matches.map { "song_id=\($0.id.rawValue) title=\($0.title) artist=\($0.artistName)" }.joined(separator: "\n"))])]),
                 "structuredContent": .object(["status": .string("search_results"), "playing": .bool(isPlaying)])])
    }

    private func result() -> JSONValue {
        refreshVolume()
        return .object(["content": .array([.object(["type": .string("text"), "text": .string("Apple Music linked=\(isLinked), catalog_playback=\(canPlayCatalogContent.map(String.init) ?? "unknown"), pet music enabled=\(enabled), player_state=\(playbackState), title=\(title), artist=\(artist). Playback state is read from MusicKit; this does not verify audible output.")])]),
                 "isError": .bool(false), "structuredContent": .object(["checking_account": .bool(isCheckingConnection), "account_error": connectionError.map(JSONValue.string) ?? .null, "linked": .bool(isLinked), "can_play_catalog": canPlayCatalogContent.map(JSONValue.bool) ?? .null, "enabled": .bool(enabled), "playing": .bool(isPlaying), "state": .string(playbackState), "title": .string(title), "owns_queue": .bool(ownsQueue), "volume_scope": .string("default_output_device"), "volume": volume.level.map(JSONValue.number) ?? .null, "volume_settable": .bool(volume.canSet), "muted": volume.muted.map(JSONValue.bool) ?? .null, "output_device": .string(volume.deviceName)])])
    }
}
