//
//  MobileLiveActivityCoordinator.swift
//  RxCodeMobile
//
//  Owns the iOS side of the job Live Activity push lifecycle.
//
//  The paired desktop is what actually starts, updates, and ends Live
//  Activities — it does so over APNs (see `MobileSyncService`). This
//  coordinator's only job is to harvest the two kinds of ActivityKit push
//  token and forward them to the desktop:
//
//   1. `Activity.pushToStartTokenUpdates` — the device-wide push-to-start
//      token (iOS 17.2+) that lets the desktop spawn an activity remotely
//      when a new job begins.
//   2. Each activity's `pushTokenUpdates` — the per-activity update token the
//      desktop targets for `update` and `end` pushes.
//

#if os(iOS)
import ActivityKit
import Combine
import Foundation
import RxCodeSync
import os.log

@MainActor
final class MobileLiveActivityCoordinator {
    private weak var state: MobileAppState?
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "LiveActivity")

    /// Latest device-wide push-to-start token.
    private var startTokenHex: String?
    /// Per-activity update tokens, keyed by `Activity.id`.
    private var activityTokens: [String: (sessionID: String, tokenHex: String)] = [:]
    private var observationStarted = false
    private var cancellables = Set<AnyCancellable>()

    /// Wire the coordinator to the app state. Safe to call once; later calls
    /// are ignored. Starts ActivityKit token observation and re-reports tokens
    /// whenever the relay reconnects.
    func bind(state: MobileAppState) {
        self.state = state
        guard !observationStarted else { return }
        observationStarted = true
        startObserving()
        state.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connectionState in
                if case .connected = connectionState {
                    self?.resendTokens()
                }
            }
            .store(in: &cancellables)
    }

    private func startObserving() {
        guard #available(iOS 16.1, *) else {
            logger.info("[LiveActivity] iOS < 16.1 — Live Activities unavailable")
            return
        }
        // ActivityKit silently drops a push-to-start when Live Activities are
        // disabled for the app — log the authorization state so a missing
        // activity can be told apart from a malformed push.
        let authInfo = ActivityAuthorizationInfo()
        if #available(iOS 17.2, *) {
            logger.info("[LiveActivity] start observing — activitiesEnabled=\(authInfo.areActivitiesEnabled, privacy: .public) frequentPushesEnabled=\(authInfo.frequentPushesEnabled, privacy: .public)")
        } else {
            logger.info("[LiveActivity] start observing — activitiesEnabled=\(authInfo.areActivitiesEnabled, privacy: .public)")
        }
        if !authInfo.areActivitiesEnabled {
            logger.warning("[LiveActivity] Live Activities are DISABLED in Settings — iOS will drop the desktop's push-to-start; enable them under Settings ▸ RxCode")
        }
        // Push-to-start token: device-wide, iOS 17.2+.
        if #available(iOS 17.2, *) {
            Task { [weak self] in
                for await tokenData in Activity<RxCodeJobActivityAttributes>.pushToStartTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    self?.handleStartToken(hex)
                }
            }
        } else {
            logger.warning("[LiveActivity] iOS < 17.2 — push-to-start unavailable; the desktop cannot spawn an activity remotely")
        }
        // Re-attach to activities already running (e.g. after a relaunch),
        // then pick up future ones as ActivityKit reports them.
        let existing = Activity<RxCodeJobActivityAttributes>.activities
        logger.info("[LiveActivity] re-attaching to \(existing.count, privacy: .public) existing activity(ies)")
        for activity in existing {
            observe(activity)
        }
        Task { [weak self] in
            for await activity in Activity<RxCodeJobActivityAttributes>.activityUpdates {
                self?.logger.info("[LiveActivity] activityUpdates reported activity id=\(activity.id, privacy: .public) — push-to-start spawned an activity")
                self?.observe(activity)
            }
        }
    }

    @available(iOS 16.1, *)
    private func observe(_ activity: Activity<RxCodeJobActivityAttributes>) {
        logger.info("[LiveActivity] observing activity id=\(activity.id, privacy: .public) session=\(activity.attributes.sessionID, privacy: .public)")
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self?.handleActivityToken(activity: activity, hex: hex)
            }
        }
    }

    private func handleStartToken(_ hex: String) {
        guard startTokenHex != hex else { return }
        startTokenHex = hex
        logger.info("[LiveActivity] push-to-start token \(hex.prefix(8), privacy: .public)…")
        Task { [weak state] in
            await state?.sendLiveActivityToken(LiveActivityTokenPayload(pushToStartTokenHex: hex))
        }
    }

    @available(iOS 16.1, *)
    private func handleActivityToken(activity: Activity<RxCodeJobActivityAttributes>, hex: String) {
        let sessionID = activity.attributes.sessionID
        guard activityTokens[activity.id]?.tokenHex != hex else { return }
        activityTokens[activity.id] = (sessionID, hex)
        logger.info("[LiveActivity] activity token id=\(activity.id, privacy: .public) session=\(sessionID, privacy: .public) \(hex.prefix(8), privacy: .public)…")
        let activityID = activity.id
        Task { [weak state] in
            await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                activityTokenHex: hex, activityID: activityID, sessionID: sessionID
            ))
        }
    }

    /// Re-send every token we hold. Called when the relay reconnects so the
    /// desktop's per-device token registry survives a disconnect.
    private func resendTokens() {
        if let startTokenHex {
            Task { [weak state] in
                await state?.sendLiveActivityToken(LiveActivityTokenPayload(pushToStartTokenHex: startTokenHex))
            }
        }
        for (activityID, entry) in activityTokens {
            Task { [weak state] in
                await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                    activityTokenHex: entry.tokenHex, activityID: activityID, sessionID: entry.sessionID
                ))
            }
        }
    }
}
#endif
