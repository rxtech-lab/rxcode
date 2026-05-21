import Foundation
import AppKit
import Combine
import CryptoKit
import RxCodeCore
import RxCodeSync
import os.log

extension MobileSyncService {

    // MARK: - Live Activity & widget push

    /// Fold a session update into the streaming-job set and the aggregate Live
    /// Activity, then push any resulting Live Activity / widget changes.
    /// Called for every `broadcastSessionUpdate`.
    func updateJobTracking(
        sessionID: String,
        kind: SessionUpdatePayload.Kind,
        isStreaming: Bool?,
        summary: RxCodeSync.SessionSummary?,
        previousSessionID: String?
    ) {
        let streamingOverride: Bool?
        switch kind {
        case .streamingStarted: streamingOverride = true
        case .streamingFinished: streamingOverride = false
        default: streamingOverride = isStreaming
        }
        // Summaries carry title/progress/todos — they drive the Live Activity.
        let content = summary.map { makeJobContent(from: $0) }
        let result = jobsTracker.ingest(
            sessionID: sessionID,
            content: content,
            streamingOverride: streamingOverride,
            previousSessionID: previousSessionID
        )
        if result.batchReset {
            // A finished batch was cleared or a job re-keyed — force the next
            // push out instead of letting the signature dedup swallow it.
            lastPushedJobsSignature = ""
        }
        if content != nil {
            // A complete → running transition wakes the activity up at once;
            // ordinary changes go through the throttle.
            pushJobsActivity(immediate: result.resumedWork)
        }
        pushWidgetUpdateIfJobCountChanged()
    }

    func makeJobContent(from summary: RxCodeSync.SessionSummary) -> JobContent {
        let isDone = !summary.isStreaming
        return JobContent(
            sessionID: summary.id,
            title: summary.title,
            projectName: projectNameResolver?(summary.projectId) ?? "",
            todoDone: summary.progress?.done ?? 0,
            todoTotal: summary.progress?.total ?? 0,
            currentStep: summary.todos?.first { $0.status == .inProgress }?.activeForm,
            isDone: isDone,
            // A finished job with no unchecked completion has been seen: it
            // either completed in the foreground or the user already viewed it.
            isRead: isDone && !summary.hasUncheckedCompletion
        )
    }

    // MARK: Aggregate Live Activity

    /// Concatenated per-job signatures — identifies a distinct rendered state.
    var jobsSignature: String { jobsTracker.jobsSignature }

    /// `true` once every tracked job has finished.
    var allJobsDone: Bool { jobsTracker.allJobsDone }

    /// `true` when some paired device has registered the aggregate activity's
    /// update token — i.e. the activity exists and can be pushed `update`s.
    var hasAnyActivityToken: Bool {
        pairedDevices.contains { !($0.liveActivityTokens ?? []).isEmpty }
    }

    /// Drive the single aggregate Live Activity from `trackedJobs`.
    ///
    /// The activity is created once with a push-to-start and then reused for
    /// the lifetime of the device session: it is never ended or auto-dismissed
    /// by the desktop, only updated. One activity for every job keeps re-runs
    /// off the scarce iOS push-to-start budget; the user dismisses it.
    ///
    /// Update pushes are throttled to one per `jobsPushInterval`: the first
    /// change in a quiet window pushes immediately, further changes coalesce
    /// into a single trailing push. This keeps bursts of job/todo events from
    /// exhausting the APNs Live Activity budget — the cause of the activity
    /// stalling on "running" after a job has finished.
    ///
    /// `immediate` skips the throttle window — used when work resumes after
    /// every job had finished, so the activity wakes up at once.
    func pushJobsActivity(immediate: Bool = false) {
        guard !trackedJobs.isEmpty else { return }
        if hasAnyActivityToken {
            guard jobsSignature != lastPushedJobsSignature else {
                logger.debug("[LiveActivity] jobs activity unchanged — skip update")
                return
            }
            let elapsed = lastJobsPushDate.map { Date().timeIntervalSince($0) }
            if !immediate, let elapsed, elapsed < Self.jobsPushInterval {
                // Inside the throttle window — coalesce into a trailing push.
                // A pending task already covers later changes: when it fires
                // it re-reads `trackedJobs`, so the latest state is sent.
                guard pendingJobsPushTask == nil else { return }
                let delay = Self.jobsPushInterval - elapsed
                logger.debug("[LiveActivity] jobs activity update coalesced — trailing push in \(Int(delay), privacy: .public)s")
                pendingJobsPushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    self.flushJobsActivityPush()
                }
            } else {
                flushJobsActivityPush()
            }
        } else if jobsActivityLocallyStarted {
            // The activity exists locally; its update token has not been
            // minted yet. The first push goes out when that token registers.
            logger.debug("[LiveActivity] jobs activity started locally — awaiting update token")
        } else {
            scheduleJobsActivityStart()
        }
    }

    /// Send the coalesced aggregate update now, if the rendered state actually
    /// changed since the last push. Reads `trackedJobs` at call time so a
    /// trailing flush always carries the latest state.
    func flushJobsActivityPush() {
        pendingJobsPushTask?.cancel()
        pendingJobsPushTask = nil
        guard !trackedJobs.isEmpty, hasAnyActivityToken else { return }
        let signature = jobsSignature
        guard signature != lastPushedJobsSignature else { return }
        lastPushedJobsSignature = signature
        lastJobsPushDate = Date()
        logger.info("[LiveActivity] jobs activity update jobs=\(self.trackedJobs.count, privacy: .public) running=\(self.trackedJobs.filter { !$0.isDone }.count, privacy: .public)")
        sendJobsActivityUpdate(staleAfter: allJobsDone ? 8 * 3600 : 3600)
    }

    /// Schedule the push-to-start after a short delay. A foregrounded device
    /// starts the activity itself (no push-to-start budget) and reports it
    /// within a second or two, cancelling this task. Only a backgrounded
    /// device ends up actually receiving the push-to-start.
    func scheduleJobsActivityStart() {
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
    func cancelJobsActivityStart() {
        if pendingStartTask != nil {
            pendingStartTask?.cancel()
            pendingStartTask = nil
            logger.debug("[LiveActivity] pending push-to-start cancelled")
        }
    }

    /// Push a `start` for the aggregate activity to every device with a
    /// push-to-start token.
    func sendJobsActivityStart() {
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
        lastJobsPushDate = now
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
    func sendJobsActivityUpdate(staleAfter: TimeInterval) {
        let now = Date()
        let payload: [String: Any] = ["aps": [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": "update",
            "content-state": jobsContentStateDict(at: now),
            "stale-date": Int(now.addingTimeInterval(staleAfter).timeIntervalSince1970),
        ]]
        pushToActivityTokens(payload: payload)
    }

    /// Push an `end` event that clears an orphaned aggregate activity — one
    /// left running by a previous desktop session that crashed or quit
    /// mid-job and never delivered the finishing update. `dismissal-date` is
    /// set to now so iOS removes it promptly instead of letting it linger on
    /// screen for the system's default window.
    func sendJobsActivityEnd(deviceToken: String, device: PairedDevice) {
        guard let pushURL = Self.pushEndpointURL(from: relayURL) else {
            logger.error("[LiveActivity] end skipped — cannot derive push endpoint from relay \(self.relayURL.absoluteString, privacy: .public)")
            return
        }
        let now = Date()
        let payload: [String: Any] = ["aps": [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": "end",
            "content-state": ["jobs": [[String: Any]](), "updatedAt": now.timeIntervalSince1970],
            "dismissal-date": Int(now.timeIntervalSince1970),
        ]]
        logger.info("[LiveActivity] end → posting push tokenPrefix=\(String(deviceToken.prefix(12)), privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
        Task {
            await postRawPush(deviceToken: deviceToken, pushType: "liveactivity",
                              apnsPayload: payload, collapseID: "rxcode-jobs-activity",
                              device: device, pushURL: pushURL)
        }
    }

    /// Build the ActivityKit `content-state` dict. Field names mirror
    /// `RxCodeJobActivityAttributes.ContentState` in the widget target.
    func jobsContentStateDict(at date: Date) -> [String: Any] {
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
    func pushToActivityTokens(payload: [String: Any]) {
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

    func pushWidgetUpdateIfJobCountChanged() {
        guard streamingSessionIDs.count != lastWidgetJobCount else { return }
        pushWidgetUpdate()
    }

    /// Push the current ongoing-job count and agent usage to every paired
    /// device as a silent background notification, refreshing the home-screen
    /// widget. Also called by `AppState` when rate-limit usage refreshes.
    ///
    /// The snapshot is E2E-encrypted per device (sealed to that device's
    /// Curve25519 key), so the relay only ever forwards opaque ciphertext.
    func pushWidgetUpdate() {
        let jobCount = streamingSessionIDs.count
        lastWidgetJobCount = jobCount
        let devices = pairedDevices.filter { ($0.apnsToken?.isEmpty == false) }
        guard !devices.isEmpty, let pushURL = Self.pushEndpointURL(from: relayURL) else { return }
        let usage = usageSnapshotProvider?()
        let snapshot = WidgetSnapshotPayload(
            jobs: jobCount,
            cc: usage?.cc,
            codex: usage?.codex,
            updatedAt: Date().timeIntervalSince1970
        )
        for device in devices {
            guard let token = device.apnsToken else { continue }
            Task {
                await sendWidgetPush(snapshot, to: device, token: token, pushURL: pushURL)
            }
        }
    }

    /// Seal the widget snapshot for one device and POST it as a silent
    /// background push. Per-device failures are logged and swallowed — widget
    /// refreshes are best-effort.
    private func sendWidgetPush(
        _ snapshot: WidgetSnapshotPayload,
        to device: PairedDevice,
        token: String,
        pushURL: URL
    ) async {
        guard let peer = await client.peer(forHex: device.pubkeyHex) else {
            logger.error("[Push] widget push skipped — unknown peer deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
            return
        }
        let encWidget: String
        do {
            let envelope = try APNsCrypto.sealWidget(
                snapshot, sender: identity.privateKey, recipient: peer
            )
            encWidget = try JSONEncoder().encode(envelope).base64EncodedString()
        } catch {
            logger.error("[Push] widget seal failed deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let payload: [String: Any] = ["aps": ["content-available": 1], "encWidget": encWidget]
        await postRawPush(deviceToken: token, pushType: "background",
                          apnsPayload: payload, collapseID: "rxcode-widget",
                          device: device, pushURL: pushURL)
    }

    /// POST a raw (Live Activity or background) push to the relay `/push`
    /// endpoint. Failures are logged and swallowed — these are best-effort.
    func postRawPush(
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
}
