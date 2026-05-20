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
import RxCodeCore
import RxCodeSync
import UIKit
import os.log

@MainActor
final class MobileLiveActivityCoordinator {
    private weak var state: MobileAppState?
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "LiveActivity")

    /// Latest device-wide push-to-start token.
    private var startTokenHex: String?
    /// Per-activity update tokens, keyed by `Activity.id`.
    private var activityTokens: [String: (sessionID: String, tokenHex: String)] = [:]
    /// Sessions for which we started a Live Activity locally (foreground path).
    /// Tracked so a burst of session updates can't start the same one twice;
    /// cleared when the user dismisses the activity.
    private var locallyStartedSessions: Set<String> = []
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
        // When the app is in the foreground a job's Live Activity can be
        // started locally with `Activity.request` — no push-to-start budget.
        // Watch the mirrored session list and start one as soon as a job
        // begins streaming; backgrounded jobs still use the desktop's push.
        state.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.startLocalActivitiesIfForeground(for: sessions)
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
        // The desktop reuses an activity across re-runs and never ends it
        // itself, so the only way it goes away is the user dismissing it.
        // Report that so the desktop forgets the activity and the next run
        // push-to-starts a fresh one instead of pushing to a dead token.
        Task { [weak self] in
            for await activityState in activity.activityStateUpdates {
                if activityState == .dismissed || activityState == .ended {
                    self?.handleActivityDismissed(activity, activityState: activityState)
                    break
                }
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

    /// The user dismissed (or the system ended) an activity. Drop our local
    /// token and tell the desktop so it forgets the activity — the next run of
    /// this session will then push-to-start a fresh one.
    @available(iOS 16.1, *)
    private func handleActivityDismissed(
        _ activity: Activity<RxCodeJobActivityAttributes>,
        activityState: ActivityState
    ) {
        let sessionID = activity.attributes.sessionID
        let activityID = activity.id
        activityTokens.removeValue(forKey: activityID)
        locallyStartedSessions.remove(sessionID)
        logger.info("[LiveActivity] activity \(String(describing: activityState), privacy: .public) id=\(activityID, privacy: .public) session=\(sessionID, privacy: .public) — reporting dismissal to desktop")
        Task { [weak state] in
            await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                activityID: activityID, sessionID: sessionID, activityDismissed: true
            ))
        }
    }

    // MARK: - Foreground local start

    /// Start a local Live Activity for every streaming job that doesn't have
    /// one yet — but only while the app is in the foreground, where
    /// `Activity.request` works without spending the push-to-start budget.
    private func startLocalActivitiesIfForeground(for sessions: [SessionSummary]) {
        guard #available(iOS 16.2, *) else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let live = Activity<RxCodeJobActivityAttributes>.activities
        for session in sessions where session.isStreaming {
            let sid = session.id
            guard !locallyStartedSessions.contains(sid),
                  !live.contains(where: { $0.attributes.sessionID == sid })
            else { continue }
            startActivityLocally(for: session)
        }
    }

    /// Create the activity in-process and observe it so its push token reaches
    /// the desktop, which then drives updates exactly as for a pushed activity.
    @available(iOS 16.2, *)
    private func startActivityLocally(for session: SessionSummary) {
        let sid = session.id
        let projectName = state?.projects.first { $0.id == session.projectId }?.name ?? ""
        let attributes = RxCodeJobActivityAttributes(
            sessionID: sid, projectName: projectName, title: session.title
        )
        let contentState = RxCodeJobActivityAttributes.ContentState(
            phase: .running,
            todoDone: session.progress?.done ?? 0,
            todoTotal: session.progress?.total ?? 0,
            currentStep: session.todos?.first { $0.status == .inProgress }?.activeForm,
            updatedAt: Date().timeIntervalSince1970
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: contentState, staleDate: Date().addingTimeInterval(3600)
                ),
                pushType: .token
            )
            locallyStartedSessions.insert(sid)
            logger.info("[LiveActivity] started locally session=\(sid, privacy: .public) id=\(activity.id, privacy: .public) — foreground, no push-to-start needed")
            observe(activity)
        } catch {
            logger.error("[LiveActivity] local start failed session=\(sid, privacy: .public): \(error.localizedDescription, privacy: .public) — desktop push-to-start will cover it")
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
