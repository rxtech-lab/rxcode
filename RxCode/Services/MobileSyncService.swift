import Foundation
import AppKit
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import os.log

/// One per-activity Live Activity push token registered by a paired mobile.
/// The desktop targets `update`/`end` pushes at `token`, scoped to `sessionID`.
struct LiveActivityTokenRef: Codable, Sendable, Hashable {
    var activityID: String
    var sessionID: String
    var token: String
}

/// One paired mobile device. Persisted to
/// `~/Library/Application Support/RxCode/paired_devices.json`.
struct PairedDevice: Codable, Identifiable, Sendable, Hashable {
    var pubkeyHex: String
    var displayName: String
    var platform: String
    var apnsToken: String?
    var apnsEnvironment: String?
    /// Device-wide Live Activity push-to-start token (iOS 17.2+). Lets the
    /// desktop spawn a job Live Activity remotely. Optional for wire/forward
    /// compatibility with paired-device files written before Live Activities.
    var liveActivityStartToken: String?
    /// Per-activity Live Activity update tokens, one per running job activity.
    var liveActivityTokens: [LiveActivityTokenRef]?
    var pairedAt: Date
    var lastSeen: Date?

    var id: String { pubkeyHex }
}

/// Result of a pairing handshake propagated to the SwiftUI pairing sheet.
enum PairingOutcome: Sendable {
    case pending
    case received(PairRequestPayload)
    case accepted(PairedDevice)
    case cancelled
}

enum MobilePushError: LocalizedError {
    case missingDeviceToken
    case unknownPeer
    case invalidRelayURL
    case relayRejected(status: Int, body: String)
    case apnsRejected(status: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingDeviceToken:
            "This device has not registered a push token yet."
        case .unknownPeer:
            "This device is not available in the encrypted peer list."
        case .invalidRelayURL:
            "The relay URL cannot be converted to a push endpoint."
        case .relayRejected(let status, let body):
            "Relay rejected the push request (\(status)): \(body)"
        case .apnsRejected(let status, let reason):
            "APNs rejected the notification (\(status)): \(reason)"
        }
    }
}

/// Bridges the desktop app to paired mobile devices over the E2E-encrypted
/// relay channel. Owns the long-term `DeviceIdentity`, the `SyncClient`, and
/// the persistent paired-device list.
@MainActor
final class MobileSyncService: ObservableObject {

    static let shared = MobileSyncService()

    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var connectionState: RelayClient.ConnectionState = .disconnected
    @Published private(set) var isPairing: Bool = false
    @Published private(set) var pendingPairing: PairRequestPayload?
    @Published var relayURL: URL

    private let logger = Logger(subsystem: "com.idealapp.RxCode", category: "MobileSync")
    private let identity: DeviceIdentity
    private var client: SyncClient
    private var subscribedSessions: [String: String] = [:]
    private var eventTask: Task<Void, Never>?
    private var pairingToken: PairingToken?
    private var pairingContinuation: CheckedContinuation<PairingOutcome, Never>?

    /// The single AppState reference is set in init order from RxCodeApp,
    /// because AppState owns the storage layer and the streaming loop.
    private weak var appState: AnyObject?

    // MARK: - Live Activity & widget state

    /// Resolves a project's display name for Live Activity attributes. Set by
    /// `AppState` after initialization; `nil` before that.
    var projectNameResolver: (@MainActor (UUID) -> String?)?
    /// Supplies the current Claude Code / Codex 5-hour usage for the widget
    /// background push. Set by `AppState`; `nil` before that.
    var usageSnapshotProvider: (@MainActor () -> (cc: Double?, codex: Double?))?

    /// Session ids currently streaming — the live job count for the widget.
    private var streamingSessionIDs: Set<String> = []
    /// Every job tracked by the single aggregate Live Activity: those still
    /// running plus recently finished ones, in start order.
    private var trackedJobs: [JobContent] = []
    /// `true` once a foregrounded device reported it started the activity
    /// locally; suppresses the push-to-start until the activity goes away.
    private var jobsActivityLocallyStarted = false
    /// Signature of the content-state last pushed, so an update only fires on
    /// a real change rather than on every session event.
    private var lastPushedJobsSignature = ""
    /// Pending deferred push-to-start. The push-to-start is delayed briefly so
    /// a foregrounded device can start the activity locally instead; this task
    /// is cancelled once a device reports it did.
    private var pendingStartTask: Task<Void, Never>?
    /// Last widget job count pushed, so a widget push only fires on a change.
    private var lastWidgetJobCount: Int = -1

    init() {
        // Persisted relay URL or sensible default for self-host.
        let stored = UserDefaults.standard.string(forKey: "mobileSync.relayURL")
        let initial = URL(string: stored ?? "ws://localhost:8787") ?? URL(string: "ws://localhost:8787")!
        self.relayURL = initial
        do {
            self.identity = try DeviceIdentity.loadOrCreate()
        } catch {
            Self.logFatalKeychain(error)
            fatalError("Failed to load device identity: \(error)")
        }
        self.client = SyncClient(identity: identity, relayURL: initial)
        loadPairedDevices()
    }

    private static func logFatalKeychain(_ error: Error) {
        Logger(subsystem: "com.idealapp.RxCode", category: "MobileSync")
            .fault("device-identity load failed: \(String(describing: error))")
    }

    // MARK: - Public API

    var localPublicKeyHex: String { identity.publicKeyHex }
    var localDeviceName: String { Host.current().localizedName ?? "Mac" }

    /// Begin (or resume) the relay connection. Safe to call multiple times.
    func start() {
        Task { @MainActor in
            logger.info("[MobileSync] starting relay=\(self.relayURL.absoluteString, privacy: .public) pairedDevices=\(self.pairedDevices.count, privacy: .public) desktopKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
            for device in pairedDevices {
                do {
                    try await client.addPeer(device.pubkeyHex)
                    logger.info("[MobileSync] added paired peer mobileKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                } catch {
                    logger.error("[MobileSync] failed to add paired peer mobileKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            // Subscribe to events BEFORE calling start() so we don't miss the
            // initial .connecting / .connected state transitions.
            let events = await client.events()
            eventTask?.cancel()
            eventTask = Task { @MainActor in
                for await event in events {
                    self.handle(event: event)
                }
            }
            await client.start()
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        Task { await client.stop() }
    }

    /// Update the configured relay URL, persist it, and reconnect.
    func updateRelay(url: URL) {
        guard url != relayURL else { return }
        logger.info("[MobileSync] relay URL changed from \(self.relayURL.absoluteString, privacy: .public) to \(url.absoluteString, privacy: .public)")
        UserDefaults.standard.set(url.absoluteString, forKey: "mobileSync.relayURL")
        relayURL = url
        eventTask?.cancel()
        eventTask = nil
        let oldClient = client
        client = SyncClient(identity: identity, relayURL: url)
        connectionState = .disconnected
        Task { await oldClient.stop() }
        start()
    }

    // MARK: - Pairing

    /// Generate a fresh pairing token + show it as QR. Token expires in 2 min.
    func beginPairing() -> PairingToken {
        let token = PairingToken(
            relayURL: relayURL.absoluteString,
            desktopPubkeyHex: identity.publicKeyHex,
            oneTimeSecretHex: PairingToken.makeOneTimeSecret(),
            expiresAt: Date.now.addingTimeInterval(120),
            desktopName: localDeviceName
        )
        pairingToken = token
        isPairing = true
        pendingPairing = nil
        return token
    }

    /// Wait until a mobile finishes the pairing handshake. Returns when the
    /// user has either approved or cancelled the pending request.
    func awaitPairing() async -> PairingOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<PairingOutcome, Never>) in
            pairingContinuation = continuation
        }
    }

    /// Accept the pending pair request shown to the user in the pairing sheet.
    func acceptPendingPairing() async {
        guard let pending = pendingPairing else { return }
        let device = PairedDevice(
            pubkeyHex: pending.mobilePubkeyHex,
            displayName: pending.displayName,
            platform: pending.platform,
            apnsToken: nil,
            apnsEnvironment: nil,
            pairedAt: .now,
            lastSeen: .now
        )
        pairedDevices.removeAll { $0.pubkeyHex == device.pubkeyHex }
        pairedDevices.append(device)
        savePairedDevices()
        try? await client.addPeer(device.pubkeyHex)
        let ack = PairAckPayload(accepted: true, desktopName: localDeviceName)
        try? await client.send(.pairAck(ack), toHex: device.pubkeyHex)
        isPairing = false
        pendingPairing = nil
        pairingToken = nil
        pairingContinuation?.resume(returning: .accepted(device))
        pairingContinuation = nil
    }

    func cancelPairing() {
        Task {
            if let pending = pendingPairing {
                let ack = PairAckPayload(accepted: false, desktopName: localDeviceName, reason: "rejected")
                try? await client.addPeer(pending.mobilePubkeyHex)
                try? await client.send(.pairAck(ack), toHex: pending.mobilePubkeyHex)
                await client.removePeer(pending.mobilePubkeyHex)
            }
        }
        isPairing = false
        pendingPairing = nil
        pairingToken = nil
        pairingContinuation?.resume(returning: .cancelled)
        pairingContinuation = nil
    }

    /// Remove a paired device and notify it before forgetting its pubkey.
    func unpair(_ device: PairedDevice) async {
        try? await client.send(.unpair(UnpairPayload(reason: "desktop")), toHex: device.pubkeyHex)
        pairedDevices.removeAll { $0.pubkeyHex == device.pubkeyHex }
        savePairedDevices()
        subscribedSessions.removeValue(forKey: device.pubkeyHex)
        await client.removePeer(device.pubkeyHex)
    }

    // MARK: - Notification fan-out

    /// Send a notification to every paired device.
    ///
    /// Two delivery paths run for each broadcast:
    /// - the live WebSocket relay channel reaches devices that are currently
    ///   connected and foregrounded;
    /// - a best-effort APNs push reaches devices that are backgrounded or
    ///   offline, so a finished thread still surfaces a banner.
    func broadcastNotification(_ payload: NotificationPayload) {
        Task {
            await client.broadcast(.notification(payload))
            await fanoutAPNs(payload)
        }
    }

    /// Best-effort APNs fan-out: submit one encrypted alert per paired device
    /// that has registered a push token. Per-device failures are logged and
    /// swallowed — the live channel above remains the primary path.
    private func fanoutAPNs(_ payload: NotificationPayload) async {
        let devices = pairedDevices.filter { ($0.apnsToken?.isEmpty == false) }
        guard !devices.isEmpty else { return }
        guard let pushURL = Self.pushEndpointURL(from: relayURL) else {
            logger.error("[APNs] cannot derive push endpoint from relay URL \(self.relayURL.absoluteString, privacy: .public)")
            return
        }
        for device in devices {
            do {
                try await sendAPNsPush(payload, to: device, pushURL: pushURL)
            } catch {
                logger.error("[APNs] fan-out failed deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Encrypt `payload` for one device and POST it to the relay `/push`
    /// endpoint. Throws on a missing token, unknown peer, or relay/APNs
    /// rejection so callers can log the specific failure.
    private func sendAPNsPush(_ payload: NotificationPayload, to device: PairedDevice, pushURL: URL) async throws {
        guard let token = device.apnsToken, !token.isEmpty else {
            throw MobilePushError.missingDeviceToken
        }
        guard let peer = await client.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }

        let plaintext = AlertPlaintext(
            title: payload.title,
            body: payload.body,
            sessionID: payload.sessionID,
            projectID: payload.projectID,
            kind: payload.kind.rawValue
        )
        let encrypted = try APNsCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: peer
        )
        let encryptedAlertData = try JSONEncoder().encode(encrypted)
        let body = APNsPushRequest(
            deviceToken: token,
            encryptedAlert: encryptedAlertData.base64EncodedString(),
            category: payload.kind.rawValue,
            collapseID: Self.notificationCollapseID(for: payload, device: device)
        )

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("[APNs] sending push kind=\(payload.kind.rawValue, privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) tokenPrefix=\(String(token.prefix(12)), privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePushError.relayRejected(status: -1, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobilePushError.relayRejected(
                status: http.statusCode,
                body: Self.responseBodyString(data)
            )
        }
        let pushResponse = try JSONDecoder().decode(APNsPushResponse.self, from: data)
        guard (200..<300).contains(pushResponse.statusCode) else {
            throw MobilePushError.apnsRejected(
                status: pushResponse.statusCode,
                reason: pushResponse.reason
            )
        }
    }

    /// Send one APNs-backed test notification to a paired device.
    func sendTestNotification(to device: PairedDevice) async throws {
        guard let token = device.apnsToken, !token.isEmpty else {
            throw MobilePushError.missingDeviceToken
        }
        guard let peer = await client.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }
        guard let pushURL = Self.pushEndpointURL(from: relayURL) else {
            throw MobilePushError.invalidRelayURL
        }

        logger.info("[APNs] sending test push deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) tokenPrefix=\(String(token.prefix(12)), privacy: .public) environment=\(device.apnsEnvironment ?? "<nil>", privacy: .public) sender=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
        let plaintext = AlertPlaintext(
            title: "RxCode test notification",
            body: "Notifications are working for \(device.displayName).",
            kind: NotificationPayload.Kind.generic.rawValue
        )
        let encrypted = try APNsCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: peer
        )
        let encryptedAlertData = try JSONEncoder().encode(encrypted)
        let body = APNsPushRequest(
            deviceToken: token,
            encryptedAlert: encryptedAlertData.base64EncodedString(),
            category: "test_notification",
            collapseID: Self.testNotificationCollapseID(for: device)
        )

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePushError.relayRejected(status: -1, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobilePushError.relayRejected(
                status: http.statusCode,
                body: Self.responseBodyString(data)
            )
        }

        let pushResponse = try JSONDecoder().decode(APNsPushResponse.self, from: data)
        guard (200..<300).contains(pushResponse.statusCode) else {
            throw MobilePushError.apnsRejected(
                status: pushResponse.statusCode,
                reason: pushResponse.reason
            )
        }
    }

    // MARK: - Streaming hooks

    /// Called by AppState's streaming loop after each StreamEvent is folded
    /// into local state.
    func broadcastSessionUpdate(
        sessionID: String,
        kind: SessionUpdatePayload.Kind,
        message: ChatMessage?,
        isStreaming: Bool?,
        isThinking: Bool? = nil,
        summary: RxCodeSync.SessionSummary? = nil,
        previousSessionID: String? = nil
    ) {
        Task {
            let payload = SessionUpdatePayload(
                sessionID: sessionID,
                kind: kind,
                message: message,
                isStreaming: isStreaming,
                isThinking: isThinking,
                summary: summary,
                previousSessionID: previousSessionID
            )
            await client.broadcast(.sessionUpdate(payload))
        }
        updateJobTracking(sessionID: sessionID, kind: kind, isStreaming: isStreaming, summary: summary)
    }

    /// Mirror the desktop's current `AskUserQuestion` queue to every paired
    /// device. Sent whenever a question is queued or resolved so mobile can
    /// surface the same queue banner + question sheet.
    func broadcastQuestionQueue(_ questions: [PendingQuestionPayload]) {
        Task {
            await client.broadcast(.questionQueue(QuestionQueuePayload(questions: questions)))
        }
    }

    func broadcastRunTaskUpdate(_ task: MobileRunTaskSnapshot) {
        Task {
            await client.broadcast(.runTaskUpdate(RunTaskUpdatePayload(task: task)))
        }
    }

    // MARK: - Live Activity & widget push

    /// Fold a session update into the streaming-job set and the aggregate Live
    /// Activity, then push any resulting Live Activity / widget changes.
    /// Called for every `broadcastSessionUpdate`.
    private func updateJobTracking(
        sessionID: String,
        kind: SessionUpdatePayload.Kind,
        isStreaming: Bool?,
        summary: RxCodeSync.SessionSummary?
    ) {
        let streaming: Bool?
        switch kind {
        case .streamingStarted: streaming = true
        case .streamingFinished: streaming = false
        default: streaming = isStreaming
        }
        if let streaming {
            if streaming { streamingSessionIDs.insert(sessionID) }
            else { streamingSessionIDs.remove(sessionID) }
        }
        // Summaries carry title/progress/todos — they drive the Live Activity.
        if let summary {
            foldSummaryIntoJobs(summary)
            pushJobsActivity()
        }
        pushWidgetUpdateIfJobCountChanged()
    }

    /// Merge one session summary into `trackedJobs`.
    ///
    /// A running session is inserted or updated. A finished session updates
    /// the job only if it is already tracked, and is otherwise ignored — the
    /// aggregate activity follows jobs it saw start. When a new job begins
    /// while every tracked job is already done, the previous (acknowledged)
    /// batch is cleared so the activity starts a fresh list.
    private func foldSummaryIntoJobs(_ summary: RxCodeSync.SessionSummary) {
        let content = makeJobContent(from: summary)
        if let idx = trackedJobs.firstIndex(where: { $0.sessionID == summary.id }) {
            trackedJobs[idx] = content
        } else if summary.isStreaming {
            if !trackedJobs.isEmpty, trackedJobs.allSatisfy(\.isDone) {
                trackedJobs.removeAll()
                lastPushedJobsSignature = ""
            }
            trackedJobs.append(content)
        }
        pruneTrackedJobs()
    }

    /// Cap the tracked-job list, dropping the oldest finished jobs first so a
    /// long-lived device never accumulates an unbounded history.
    private func pruneTrackedJobs() {
        let cap = 6
        while trackedJobs.count > cap {
            if let doneIdx = trackedJobs.firstIndex(where: \.isDone) {
                trackedJobs.remove(at: doneIdx)
            } else {
                trackedJobs.removeFirst()
            }
        }
    }

    private func makeJobContent(from summary: RxCodeSync.SessionSummary) -> JobContent {
        JobContent(
            sessionID: summary.id,
            title: summary.title,
            projectName: projectNameResolver?(summary.projectId) ?? "",
            todoDone: summary.progress?.done ?? 0,
            todoTotal: summary.progress?.total ?? 0,
            currentStep: summary.todos?.first { $0.status == .inProgress }?.activeForm,
            isDone: !summary.isStreaming
        )
    }

    // MARK: Aggregate Live Activity

    /// Concatenated per-job signatures — identifies a distinct rendered state.
    private var jobsSignature: String {
        trackedJobs.map(\.signature).joined(separator: ";")
    }

    /// `true` once every tracked job has finished.
    private var allJobsDone: Bool {
        !trackedJobs.isEmpty && trackedJobs.allSatisfy(\.isDone)
    }

    /// `true` when some paired device has registered the aggregate activity's
    /// update token — i.e. the activity exists and can be pushed `update`s.
    private var hasAnyActivityToken: Bool {
        pairedDevices.contains { !($0.liveActivityTokens ?? []).isEmpty }
    }

    /// Drive the single aggregate Live Activity from `trackedJobs`.
    ///
    /// The activity is created once with a push-to-start and then reused for
    /// the lifetime of the device session: it is never ended or auto-dismissed
    /// by the desktop, only updated. One activity for every job keeps re-runs
    /// off the scarce iOS push-to-start budget; the user dismisses it.
    private func pushJobsActivity() {
        guard !trackedJobs.isEmpty else { return }
        let staleAfter: TimeInterval = allJobsDone ? 8 * 3600 : 3600
        if hasAnyActivityToken {
            let signature = jobsSignature
            guard signature != lastPushedJobsSignature else {
                logger.debug("[LiveActivity] jobs activity unchanged — skip update")
                return
            }
            lastPushedJobsSignature = signature
            logger.info("[LiveActivity] jobs activity update jobs=\(self.trackedJobs.count, privacy: .public) running=\(self.trackedJobs.filter { !$0.isDone }.count, privacy: .public)")
            sendJobsActivityUpdate(staleAfter: staleAfter)
        } else if jobsActivityLocallyStarted {
            // The activity exists locally; its update token has not been
            // minted yet. The first push goes out when that token registers.
            logger.debug("[LiveActivity] jobs activity started locally — awaiting update token")
        } else {
            scheduleJobsActivityStart()
        }
    }

    /// Schedule the push-to-start after a short delay. A foregrounded device
    /// starts the activity itself (no push-to-start budget) and reports it
    /// within a second or two, cancelling this task. Only a backgrounded
    /// device ends up actually receiving the push-to-start.
    private func scheduleJobsActivityStart() {
        guard pendingStartTask == nil else { return }
        logger.info("[LiveActivity] scheduling jobs activity push-to-start in 5s")
        pendingStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.pendingStartTask = nil
            guard !self.trackedJobs.isEmpty else { return }
            guard !self.hasAnyActivityToken, !self.jobsActivityLocallyStarted else {
                self.logger.info("[LiveActivity] push-to-start skipped — a device already has the activity")
                return
            }
            self.sendJobsActivityStart()
        }
    }

    /// Cancel a pending push-to-start — the activity already exists.
    private func cancelJobsActivityStart() {
        if pendingStartTask != nil {
            pendingStartTask?.cancel()
            pendingStartTask = nil
            logger.debug("[LiveActivity] pending push-to-start cancelled")
        }
    }

    /// Push a `start` for the aggregate activity to every device with a
    /// push-to-start token.
    private func sendJobsActivityStart() {
        let devices = pairedDevices.filter { ($0.liveActivityStartToken?.isEmpty == false) }
        guard !devices.isEmpty else {
            logger.warning("[LiveActivity] start skipped — no paired device has a push-to-start token (pairedDevices=\(self.pairedDevices.count, privacy: .public))")
            return
        }
        guard let pushURL = Self.pushEndpointURL(from: relayURL) else {
            logger.error("[LiveActivity] start skipped — cannot derive push endpoint from relay \(self.relayURL.absoluteString, privacy: .public)")
            return
        }
        let now = Date()
        let staleAfter: TimeInterval = allJobsDone ? 8 * 3600 : 3600
        let payload: [String: Any] = ["aps": [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": "start",
            "content-state": jobsContentStateDict(at: now),
            "attributes-type": "RxCodeJobActivityAttributes",
            "attributes": [String: Any](),
            "stale-date": Int(now.addingTimeInterval(staleAfter).timeIntervalSince1970),
        ]]
        lastPushedJobsSignature = jobsSignature
        logger.info("[LiveActivity] start jobs activity devices=\(devices.count, privacy: .public) jobs=\(self.trackedJobs.count, privacy: .public)")
        for device in devices {
            guard let token = device.liveActivityStartToken else { continue }
            logger.info("[LiveActivity] start → posting push startTokenPrefix=\(String(token.prefix(12)), privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
            Task {
                await postRawPush(deviceToken: token, pushType: "liveactivity",
                                  apnsPayload: payload, collapseID: nil, device: device, pushURL: pushURL)
            }
        }
    }

    /// Push an `update` for the aggregate activity. `staleAfter` sets when the
    /// activity dims — long for the terminal all-done state, which stays on
    /// screen until the user dismisses it. No `end` is ever sent.
    private func sendJobsActivityUpdate(staleAfter: TimeInterval) {
        let now = Date()
        let payload: [String: Any] = ["aps": [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": "update",
            "content-state": jobsContentStateDict(at: now),
            "stale-date": Int(now.addingTimeInterval(staleAfter).timeIntervalSince1970),
        ]]
        pushToActivityTokens(payload: payload)
    }

    /// Build the ActivityKit `content-state` dict. Field names mirror
    /// `RxCodeJobActivityAttributes.ContentState` in the widget target.
    private func jobsContentStateDict(at date: Date) -> [String: Any] {
        let jobs: [[String: Any]] = trackedJobs.map { job in
            var dict: [String: Any] = [
                "id": job.sessionID,
                "phase": job.isDone ? "done" : "running",
                "title": job.title,
                "projectName": job.projectName,
                "todoDone": job.todoDone,
                "todoTotal": job.todoTotal,
            ]
            if let step = job.currentStep, !step.isEmpty {
                dict["currentStep"] = step
            }
            return dict
        }
        return ["jobs": jobs, "updatedAt": date.timeIntervalSince1970]
    }

    /// Push a Live Activity payload to every registered aggregate-activity
    /// token (one per paired device).
    private func pushToActivityTokens(payload: [String: Any]) {
        guard let pushURL = Self.pushEndpointURL(from: relayURL) else {
            logger.error("[LiveActivity] update skipped — cannot derive push endpoint from relay \(self.relayURL.absoluteString, privacy: .public)")
            return
        }
        var matched = 0
        for device in pairedDevices {
            for ref in (device.liveActivityTokens ?? []) {
                matched += 1
                logger.info("[LiveActivity] push → activity token activity=\(ref.activityID, privacy: .public) tokenPrefix=\(String(ref.token.prefix(12)), privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                Task {
                    await postRawPush(deviceToken: ref.token, pushType: "liveactivity",
                                      apnsPayload: payload, collapseID: "rxcode-jobs-activity",
                                      device: device, pushURL: pushURL)
                }
            }
        }
        if matched == 0 {
            logger.warning("[LiveActivity] update has no registered activity token — the mobile never reported one")
        }
    }

    private func pushWidgetUpdateIfJobCountChanged() {
        guard streamingSessionIDs.count != lastWidgetJobCount else { return }
        pushWidgetUpdate()
    }

    /// Push the current ongoing-job count and agent usage to every paired
    /// device as a silent background notification, refreshing the home-screen
    /// widget. Also called by `AppState` when rate-limit usage refreshes.
    func pushWidgetUpdate() {
        let jobCount = streamingSessionIDs.count
        lastWidgetJobCount = jobCount
        let devices = pairedDevices.filter { ($0.apnsToken?.isEmpty == false) }
        guard !devices.isEmpty, let pushURL = Self.pushEndpointURL(from: relayURL) else { return }
        let usage = usageSnapshotProvider?()
        var widget: [String: Any] = [
            "jobs": jobCount,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let cc = usage?.cc { widget["cc"] = cc }
        if let codex = usage?.codex { widget["codex"] = codex }
        let payload: [String: Any] = ["aps": ["content-available": 1], "widget": widget]
        for device in devices {
            guard let token = device.apnsToken else { continue }
            Task {
                await postRawPush(deviceToken: token, pushType: "background",
                                  apnsPayload: payload, collapseID: "rxcode-widget",
                                  device: device, pushURL: pushURL)
            }
        }
    }

    /// POST a raw (Live Activity or background) push to the relay `/push`
    /// endpoint. Failures are logged and swallowed — these are best-effort.
    private func postRawPush(
        deviceToken: String,
        pushType: String,
        apnsPayload: [String: Any],
        collapseID: String?,
        device: PairedDevice,
        pushURL: URL
    ) async {
        var bodyDict: [String: Any] = [
            "device_token": deviceToken,
            "push_type": pushType,
            "apns_payload": apnsPayload,
        ]
        if let collapseID { bodyDict["collapse_id"] = collapseID }
        do {
            let httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            var request = URLRequest(url: pushURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = httpBody
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            guard (200..<300).contains(http.statusCode) else {
                logger.error("[Push] \(pushType, privacy: .public) relay rejected status=\(http.statusCode, privacy: .public) body=\(Self.responseBodyString(data), privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                return
            }
            if let pushResponse = try? JSONDecoder().decode(APNsPushResponse.self, from: data) {
                if (200..<300).contains(pushResponse.statusCode) {
                    logger.info("[Push] \(pushType, privacy: .public) accepted apnsStatus=\(pushResponse.statusCode, privacy: .public) apnsID=\(pushResponse.apnsID ?? "<nil>", privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                } else {
                    logger.error("[Push] \(pushType, privacy: .public) apns rejected status=\(pushResponse.statusCode, privacy: .public) reason=\(pushResponse.reason, privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                }
            } else {
                logger.info("[Push] \(pushType, privacy: .public) relay accepted httpStatus=\(http.statusCode, privacy: .public) (no APNs detail in response) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
            }
        } catch {
            logger.error("[Push] \(pushType, privacy: .public) failed deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Event dispatch

    private func handle(event: RelayClient.Event) {
        switch event {
        case .stateChanged(let s):
            connectionState = s
            logger.info("[MobileSync] relay state=\(String(describing: s), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public)")
        case .deliveryFailed(let toHex):
            // Drop-on-offline policy — desktop ignores, mobile will resync on
            // next reconnect.
            logger.warning("[MobileSync] relay delivery failed to mobileKey=\(String(toHex.prefix(12)), privacy: .public)")
        case .inbound(let inbound):
            handleInbound(inbound)
        }
    }

    private func handleInbound(_ inbound: RelayClient.Inbound) {
        switch inbound.payload {
        case .pairRequest(let req):
            pendingPairing = req
            Task { try? await client.addPeer(req.mobilePubkeyHex) }
        case .unpair:
            guard isPairedPeer(inbound.fromHex) else { return }
            handleRemoteUnpair(pubkeyHex: inbound.fromHex)
        case .apnsToken(let t):
            if let idx = pairedDevices.firstIndex(where: { $0.pubkeyHex == inbound.fromHex }) {
                logger.info("[APNs] token received mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public) environment=\(t.environment, privacy: .public)")
                pairedDevices[idx].apnsToken = t.tokenHex
                pairedDevices[idx].apnsEnvironment = t.environment
                pairedDevices[idx].lastSeen = .now
                for staleIdx in pairedDevices.indices where staleIdx != idx && pairedDevices[staleIdx].apnsToken == t.tokenHex {
                    logger.warning("[APNs] clearing duplicate token from stale mobileKey=\(String(self.pairedDevices[staleIdx].pubkeyHex.prefix(12)), privacy: .public) currentMobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public)")
                    pairedDevices[staleIdx].apnsToken = nil
                    pairedDevices[staleIdx].apnsEnvironment = nil
                }
                savePairedDevices()
            } else {
                logger.warning("[APNs] token received for unknown mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) tokenPrefix=\(String(t.tokenHex.prefix(12)), privacy: .public) environment=\(t.environment, privacy: .public)")
            }
        case .liveActivityToken(let t):
            guard let idx = pairedDevices.firstIndex(where: { $0.pubkeyHex == inbound.fromHex }) else {
                logger.warning("[LiveActivity] token received for unknown mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                return
            }
            if let startToken = t.pushToStartTokenHex, !startToken.isEmpty {
                pairedDevices[idx].liveActivityStartToken = startToken
                logger.info("[LiveActivity] push-to-start token registered mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            }
            if t.activityDismissed == true {
                // The user swiped the aggregate Live Activity away. Forget
                // this device's update token; once no device tracks the
                // activity the next job push-to-starts a fresh one.
                if var refs = pairedDevices[idx].liveActivityTokens {
                    refs.removeAll { t.activityID == nil || $0.activityID == t.activityID }
                    pairedDevices[idx].liveActivityTokens = refs.isEmpty ? nil : refs
                }
                if !hasAnyActivityToken {
                    jobsActivityLocallyStarted = false
                    lastPushedJobsSignature = ""
                    cancelJobsActivityStart()
                }
                logger.info("[LiveActivity] aggregate activity dismissed by user activity=\(t.activityID ?? "<nil>", privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            } else if t.activityStartedLocally == true {
                // A foregrounded device started the activity itself with
                // `Activity.request` and reported it the instant it was
                // created — long before APNs mints the update token. Cancel
                // the deferred push-to-start so iOS never spawns a duplicate.
                jobsActivityLocallyStarted = true
                cancelJobsActivityStart()
                logger.info("[LiveActivity] device started aggregate activity locally mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) — deferred push-to-start cancelled")
            } else if let activityToken = t.activityTokenHex, !activityToken.isEmpty,
                      let activityID = t.activityID {
                // One aggregate activity per device — replace any prior token.
                pairedDevices[idx].liveActivityTokens = [
                    LiveActivityTokenRef(activityID: activityID, sessionID: "", token: activityToken)
                ]
                logger.info("[LiveActivity] aggregate activity token registered activity=\(activityID, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
                cancelJobsActivityStart()
                // Push the latest known state straight away so a freshly
                // started activity isn't left blank until the next change.
                if !trackedJobs.isEmpty {
                    lastPushedJobsSignature = jobsSignature
                    sendJobsActivityUpdate(staleAfter: allJobsDone ? 8 * 3600 : 3600)
                }
            }
            pairedDevices[idx].lastSeen = .now
            savePairedDevices()
        case .requestSnapshot(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "request_snapshot") else { return }
            logger.info("[MobileSync] snapshot requested by mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public) activeSession=\(req.activeSessionID ?? "<nil>", privacy: .public)")
            // AppState owns the data; it observes pendingSnapshotRequests
            // and replies. Stub for now — wired up by AppState bridge.
            var userInfo: [String: Any] = ["from": inbound.fromHex]
            userInfo["activeSessionID"] = req.activeSessionID
            NotificationCenter.default.post(
                name: .mobileSyncSnapshotRequested,
                object: nil,
                userInfo: userInfo
            )
        case .settingsUpdate(let update):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "settings_update") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncSettingsUpdateReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": update]
            )
        case .userMessage(let msg):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "user_message") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncUserMessageReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": msg]
            )
        case .cancelStream(let cancel):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "cancel_stream") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncCancelStreamRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": cancel]
            )
        case .removeQueuedMessage(let payload):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "remove_queued_message") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncRemoveQueuedRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": payload]
            )
        case .newSessionRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "new_session_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncNewSessionRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .threadActionRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "thread_action_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncThreadActionRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .loadMoreMessages(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "load_more_messages") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncLoadMoreMessagesRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .searchRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "search_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncSearchRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .threadChangesRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "thread_changes_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncThreadChangesRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .subscribeSession(let sub):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "subscribe_session") else { return }
            subscribedSessions[inbound.fromHex] = sub.sessionID ?? ""
            var userInfo: [String: Any] = ["from": inbound.fromHex]
            userInfo["activeSessionID"] = sub.sessionID
            NotificationCenter.default.post(
                name: .mobileSyncSnapshotRequested,
                object: nil,
                userInfo: userInfo
            )
        case .permissionResponse(let resp):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "permission_response") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncPermissionResponse,
                object: nil,
                userInfo: ["payload": resp]
            )
        case .questionAnswer(let answer):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "question_answer") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncQuestionAnswerReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": answer]
            )
        case .planDecision(let decision):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "plan_decision") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncPlanDecisionReceived,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": decision]
            )
        case .branchOpRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "branch_op_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncBranchOpRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .folderTreeRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "folder_tree_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncFolderTreeRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .createProjectRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "create_project_request") else { return }
            NotificationCenter.default.post(
                name: .mobileSyncCreateProjectRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .runProfileMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "run_profile_mutation_request") else { return }
            logger.info("[MobileSync] run profile mutation requested operation=\(req.operation.rawValue, privacy: .public) project=\(req.projectID.uuidString, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncRunProfileMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .runProfileRunRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "run_profile_run_request") else { return }
            logger.info("[MobileSync] run profile start requested project=\(req.projectID.uuidString, privacy: .public) profile=\(req.profileID.uuidString, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncRunProfileRunRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .runProfileStopRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "run_profile_stop_request") else { return }
            logger.info("[MobileSync] run profile stop requested task=\(req.taskID?.uuidString ?? "<nil>", privacy: .public) project=\(req.projectID?.uuidString ?? "<nil>", privacy: .public) profile=\(req.profileID?.uuidString ?? "<nil>", privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncRunProfileStopRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .skillCatalogRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "skill_catalog_request") else { return }
            logger.info("[MobileSync] skill catalog requested forceRefresh=\(req.forceRefresh, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncSkillCatalogRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .skillMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "skill_mutation_request") else { return }
            logger.info("[MobileSync] skill mutation requested operation=\(req.operation.rawValue, privacy: .public) plugin=\(req.pluginID, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncSkillMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .acpRegistryRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "acp_registry_request") else { return }
            logger.info("[MobileSync] acp registry requested forceRefresh=\(req.forceRefresh, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncACPRegistryRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .acpMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "acp_mutation_request") else { return }
            logger.info("[MobileSync] acp mutation requested operation=\(req.operation.rawValue, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncACPMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .mcpConfigRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "mcp_config_request") else { return }
            logger.info("[MobileSync] mcp config requested mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncMCPConfigRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .mcpMutationRequest(let req):
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "mcp_mutation_request") else { return }
            logger.info("[MobileSync] mcp mutation requested operation=\(req.operation.rawValue, privacy: .public) server=\(req.serverName, privacy: .public) mobileKey=\(String(inbound.fromHex.prefix(12)), privacy: .public)")
            NotificationCenter.default.post(
                name: .mobileSyncMCPMutationRequested,
                object: nil,
                userInfo: ["from": inbound.fromHex, "payload": req]
            )
        case .ping:
            guard acceptPairedOnlyPayload(from: inbound.fromHex, type: "ping") else { return }
            Task { try? await client.send(.pong(PongPayload()), toHex: inbound.fromHex) }
        default:
            break
        }
    }

    private func isPairedPeer(_ pubkeyHex: String) -> Bool {
        pairedDevices.contains { $0.pubkeyHex == pubkeyHex }
    }

    private func acceptPairedOnlyPayload(from pubkeyHex: String, type: String) -> Bool {
        guard isPairedPeer(pubkeyHex) else {
            logger.warning("[MobileSync] rejecting \(type, privacy: .public) from unknown mobileKey=\(String(pubkeyHex.prefix(12)), privacy: .public)")
            Task {
                try? await client.addPeer(pubkeyHex)
                try? await client.send(.unpair(UnpairPayload(reason: "unknown_peer")), toHex: pubkeyHex)
                await client.removePeer(pubkeyHex)
            }
            return false
        }
        return true
    }

    private func handleRemoteUnpair(pubkeyHex: String) {
        guard pairedDevices.contains(where: { $0.pubkeyHex == pubkeyHex }) else {
            Task { await client.removePeer(pubkeyHex) }
            return
        }

        pairedDevices.removeAll { $0.pubkeyHex == pubkeyHex }
        savePairedDevices()
        subscribedSessions.removeValue(forKey: pubkeyHex)
        logger.info("[MobileSync] removed paired device after remote unpair")
        Task { await client.removePeer(pubkeyHex) }
    }

    /// Send a payload to a single peer (used by AppState when replying to
    /// `request_snapshot` etc).
    func send(_ payload: Payload, toHex hex: String) async {
        do {
            try await client.send(payload, toHex: hex)
            logger.debug("[MobileSync] sent type=\(payload.logName, privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public)")
        } catch {
            logger.error("[MobileSync] send failed type=\(payload.logName, privacy: .public) to mobileKey=\(String(hex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Persistence

    private var pairedDevicesURL: URL {
        AppSupport.bundleScopedURL.appendingPathComponent("paired_devices.json")
    }

    private func loadPairedDevices() {
        guard let data = try? Data(contentsOf: pairedDevicesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        pairedDevices = (try? decoder.decode([PairedDevice].self, from: data)) ?? []
    }

    private func savePairedDevices() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(pairedDevices)
            try data.write(to: pairedDevicesURL, options: .atomic)
        } catch {
            logger.error("save paired_devices.json: \(error.localizedDescription)")
        }
    }

    private static func pushEndpointURL(from relayURL: URL) -> URL? {
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }

        var path = components.path
        if path.isEmpty || path == "/" {
            path = "/push"
        } else {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = trimmed.split(separator: "/").last == "ws"
                ? trimmed.split(separator: "/").dropLast().joined(separator: "/")
                : trimmed
            path = "/" + ([base, "push"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        components.path = path
        components.queryItems = nil
        return components.url
    }

    private static func responseBodyString(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Empty response" : raw
    }

    private static func testNotificationCollapseID(for device: PairedDevice) -> String {
        "rxcode-test-\(device.pubkeyHex.prefix(32))"
    }

    /// Collapse repeated alerts for the same session + kind so a device shows
    /// the latest banner instead of stacking one per stream event.
    private static func notificationCollapseID(for payload: NotificationPayload, device: PairedDevice) -> String {
        let scope = payload.sessionID ?? "global"
        return "rxcode-\(payload.kind.rawValue)-\(scope.prefix(48))"
    }
}

private struct APNsPushRequest: Codable {
    let deviceToken: String
    let encryptedAlert: String
    let category: String?
    let collapseID: String?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case encryptedAlert = "encrypted_alert"
        case category
        case collapseID = "collapse_id"
    }
}

private struct APNsPushResponse: Codable {
    let statusCode: Int
    let reason: String
    let apnsID: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case reason
        case apnsID = "apns_id"
    }
}

/// Latest content the desktop knows for one job in the aggregate Live
/// Activity. Stored in `MobileSyncService.trackedJobs` in start order.
private struct JobContent {
    var sessionID: String
    var title: String
    var projectName: String
    var todoDone: Int
    var todoTotal: Int
    var currentStep: String?
    /// `true` once the job has finished. It shows the "done" phase but stays
    /// in the aggregate list so the activity can report the completed batch.
    var isDone: Bool

    /// Identifies a distinct rendered state for one job, so an update only
    /// pushes on a real change rather than on every session event. Includes
    /// `title` so the activity refreshes when the desktop swaps in an
    /// AI-summarized title.
    var signature: String {
        "\(sessionID)|\(isDone ? "done" : "run")|\(title)|\(todoDone)/\(todoTotal)|\(currentStep ?? "")"
    }
}

extension Notification.Name {
    static let mobileSyncSnapshotRequested = Notification.Name("mobileSync.snapshotRequested")
    static let mobileSyncUserMessageReceived = Notification.Name("mobileSync.userMessageReceived")
    static let mobileSyncCancelStreamRequested = Notification.Name("mobileSync.cancelStreamRequested")
    static let mobileSyncRemoveQueuedRequested = Notification.Name("mobileSync.removeQueuedRequested")
    static let mobileSyncNewSessionRequested = Notification.Name("mobileSync.newSessionRequested")
    static let mobileSyncThreadActionRequested = Notification.Name("mobileSync.threadActionRequested")
    static let mobileSyncLoadMoreMessagesRequested = Notification.Name("mobileSync.loadMoreMessagesRequested")
    static let mobileSyncSearchRequested = Notification.Name("mobileSync.searchRequested")
    static let mobileSyncThreadChangesRequested = Notification.Name("mobileSync.threadChangesRequested")
    static let mobileSyncSettingsUpdateReceived = Notification.Name("mobileSync.settingsUpdateReceived")
    static let mobileSyncPermissionResponse = Notification.Name("mobileSync.permissionResponse")
    static let mobileSyncQuestionAnswerReceived = Notification.Name("mobileSync.questionAnswerReceived")
    static let mobileSyncPlanDecisionReceived = Notification.Name("mobileSync.planDecisionReceived")
    static let mobileSyncBranchOpRequested = Notification.Name("mobileSync.branchOpRequested")
    static let mobileSyncFolderTreeRequested = Notification.Name("mobileSync.folderTreeRequested")
    static let mobileSyncCreateProjectRequested = Notification.Name("mobileSync.createProjectRequested")
    static let mobileSyncRunProfileMutationRequested = Notification.Name("mobileSync.runProfileMutationRequested")
    static let mobileSyncRunProfileRunRequested = Notification.Name("mobileSync.runProfileRunRequested")
    static let mobileSyncRunProfileStopRequested = Notification.Name("mobileSync.runProfileStopRequested")
    static let mobileSyncSkillCatalogRequested = Notification.Name("mobileSync.skillCatalogRequested")
    static let mobileSyncSkillMutationRequested = Notification.Name("mobileSync.skillMutationRequested")
    static let mobileSyncACPRegistryRequested = Notification.Name("mobileSync.acpRegistryRequested")
    static let mobileSyncACPMutationRequested = Notification.Name("mobileSync.acpMutationRequested")
    static let mobileSyncMCPConfigRequested = Notification.Name("mobileSync.mcpConfigRequested")
    static let mobileSyncMCPMutationRequested = Notification.Name("mobileSync.mcpMutationRequested")
}
