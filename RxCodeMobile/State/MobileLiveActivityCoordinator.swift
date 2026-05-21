//
//  MobileLiveActivityCoordinator.swift
//  RxCodeMobile
//
//  Owns the iOS side of the aggregate job Live Activity push lifecycle.
//
//  RxCode shows a *single* Live Activity per device that aggregates every
//  in-progress agent job. One activity — no matter how many jobs run — keeps
//  the app well within the scarce iOS push-to-start budget.
//
//  The paired desktop is what actually starts, updates, and ends the activity
//  over APNs (see `MobileSyncService`). This coordinator harvests the two
//  kinds of ActivityKit push token and forwards them to the desktop:
//
//   1. `Activity.pushToStartTokenUpdates` — the device-wide push-to-start
//      token (iOS 17.2+) that lets the desktop spawn the activity remotely.
//   2. The activity's `pushTokenUpdates` — the update token the desktop
//      targets for `update` pushes.
//
//  While the app is foregrounded the activity is instead started locally with
//  `Activity.request`, which spends no push-to-start budget.
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
    /// `Activity.id` of the single aggregate activity, once it exists.
    private var currentActivityID: String?
    /// Latest per-activity update token for the aggregate activity.
    private var activityTokenHex: String?
    /// `true` once this app started the aggregate activity locally; cleared
    /// when the activity is dismissed.
    private var locallyStarted = false
    /// Activity ids this coordinator is ending on purpose to clear a
    /// duplicate. Their `.ended` state must not be reported to the desktop as
    /// a user dismissal — the device keeps its surviving activity.
    private var intentionallyEndedActivityIDs: Set<String> = []
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
        // When the app is in the foreground the activity can be started
        // locally with `Activity.request` — no push-to-start budget. Watch the
        // mirrored session list and start it as soon as the first job begins;
        // backgrounded jobs still rely on the desktop's push-to-start.
        state.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.startActivityIfNeeded(for: sessions)
                if #available(iOS 16.2, *) {
                    self?.reconcileActivities(for: sessions)
                }
            }
            .store(in: &cancellables)
        // The desktop drives the activity and never ends it, so a lost
        // finishing push can leave it stuck on "Working". Re-check whenever
        // the app is foregrounded — the moment the user is most likely to be
        // looking at a stalled activity and expecting it gone.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileActivities() }
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
            logger.warning("[LiveActivity] iOS < 17.2 — push-to-start unavailable; the desktop cannot spawn the activity remotely")
        }
        // Re-attach to an activity already running (e.g. after a relaunch),
        // then pick up future ones as ActivityKit reports them.
        let existing = Activity<RxCodeJobActivityAttributes>.activities
        logger.info("[LiveActivity] re-attaching to \(existing.count, privacy: .public) existing activity(ies)")
        for activity in existing {
            observe(activity)
        }
        if #available(iOS 16.2, *) { endExtraActivities() }
        Task { [weak self] in
            for await activity in Activity<RxCodeJobActivityAttributes>.activityUpdates {
                self?.logger.info("[LiveActivity] activityUpdates reported activity id=\(activity.id, privacy: .public) — push-to-start spawned the activity")
                self?.observe(activity)
                if #available(iOS 16.2, *) { self?.endExtraActivities() }
            }
        }
    }

    @available(iOS 16.1, *)
    private func observe(_ activity: Activity<RxCodeJobActivityAttributes>) {
        currentActivityID = activity.id
        logger.info("[LiveActivity] observing aggregate activity id=\(activity.id, privacy: .public)")
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self?.handleActivityToken(activity: activity, hex: hex)
            }
        }
        // The desktop reuses the activity and never ends it itself, so the
        // only way it goes away is the user dismissing it. Report that so the
        // desktop forgets the activity and the next job push-to-starts a fresh
        // one instead of pushing to a dead token.
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
        guard activityTokenHex != hex else { return }
        activityTokenHex = hex
        currentActivityID = activity.id
        logger.info("[LiveActivity] aggregate activity token id=\(activity.id, privacy: .public) \(hex.prefix(8), privacy: .public)…")
        let activityID = activity.id
        Task { [weak state] in
            await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                activityTokenHex: hex, activityID: activityID
            ))
        }
    }

    /// The user dismissed (or the system ended) the activity. Drop our local
    /// token and tell the desktop so it forgets the activity — the next job
    /// will then push-to-start a fresh one.
    @available(iOS 16.1, *)
    private func handleActivityDismissed(
        _ activity: Activity<RxCodeJobActivityAttributes>,
        activityState: ActivityState
    ) {
        let activityID = activity.id
        if intentionallyEndedActivityIDs.remove(activityID) != nil {
            // We ended this activity ourselves to clear a duplicate; the
            // surviving activity still stands, so this is not a user dismissal
            // and must not be reported to the desktop.
            logger.info("[LiveActivity] duplicate activity \(String(describing: activityState), privacy: .public) id=\(activityID, privacy: .public) — not reporting as dismissal")
            return
        }
        if currentActivityID == activityID {
            currentActivityID = nil
            activityTokenHex = nil
            locallyStarted = false
        }
        logger.info("[LiveActivity] aggregate activity \(String(describing: activityState), privacy: .public) id=\(activityID, privacy: .public) — reporting dismissal to desktop")
        Task { [weak state] in
            await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                activityID: activityID, activityDismissed: true
            ))
        }
    }

    // MARK: - Foreground local start

    /// Start the aggregate Live Activity if jobs are running and it does not
    /// exist yet — but only while the app is in the foreground, where
    /// `Activity.request` works without spending the push-to-start budget.
    private func startActivityIfNeeded(for sessions: [SessionSummary]) {
        guard #available(iOS 16.2, *) else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // One aggregate activity total — nothing to do if it already exists.
        guard Activity<RxCodeJobActivityAttributes>.activities.isEmpty, !locallyStarted else {
            return
        }
        let running = sessions.filter(\.isStreaming)
        guard !running.isEmpty else { return }
        startActivityLocally(running: running)
    }

    /// Create the activity in-process and observe it so its push token reaches
    /// the desktop, which then drives updates exactly as for a pushed activity.
    @available(iOS 16.2, *)
    private func startActivityLocally(running: [SessionSummary]) {
        let contentState = makeContentState(running: running)
        do {
            let activity = try Activity.request(
                attributes: RxCodeJobActivityAttributes(),
                content: ActivityContent(
                    state: contentState, staleDate: Date().addingTimeInterval(3600)
                ),
                pushType: .token
            )
            locallyStarted = true
            currentActivityID = activity.id
            logger.info("[LiveActivity] started aggregate activity locally id=\(activity.id, privacy: .public) jobs=\(running.count, privacy: .public) — foreground, no push-to-start needed")
            // Tell the desktop right now — before the per-activity push token,
            // which APNs can take several seconds to mint — so it cancels the
            // deferred push-to-start and never spawns a duplicate activity.
            let activityID = activity.id
            Task { [weak state] in
                await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                    activityID: activityID, activityStartedLocally: true
                ))
            }
            observe(activity)
            endExtraActivities()
        } catch {
            logger.error("[LiveActivity] local start failed: \(error.localizedDescription, privacy: .public) — desktop push-to-start will cover it")
        }
    }

    /// Build an aggregate content-state from the currently streaming sessions.
    /// The desktop reconciles it with the full picture (including finished
    /// jobs) the moment the per-activity token registers.
    private func makeContentState(running: [SessionSummary]) -> RxCodeJobActivityAttributes.ContentState {
        let jobs = running.map { session in
            RxCodeJobActivityAttributes.ContentState.Job(
                id: session.id,
                phase: .running,
                title: session.title,
                projectName: state?.projects.first { $0.id == session.projectId }?.name ?? "",
                todoDone: session.progress?.done ?? 0,
                todoTotal: session.progress?.total ?? 0,
                currentStep: session.todos?.first { $0.status == .inProgress }?.activeForm
            )
        }
        return RxCodeJobActivityAttributes.ContentState(
            jobs: jobs, updatedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: - Stalled-activity reconciliation

    /// Longest a job activity may go without a desktop update before, with the
    /// relay also down, it is treated as dead and ended. A live job refreshes
    /// the activity far more often; a window this long only ever catches an
    /// activity whose desktop crashed or quit mid-job.
    private let staleActivityEndThreshold: TimeInterval = 2 * 3600

    /// Reconcile every live job activity against the latest app state. Safe
    /// from any trigger except the `$sessions` sink, where app state has not
    /// yet committed the new value — pass it explicitly there instead.
    private func reconcileActivities() {
        guard #available(iOS 16.2, *) else { return }
        reconcileActivities(for: state?.sessions ?? [])
    }

    /// Heal a job Live Activity the desktop left stalled.
    ///
    /// The desktop drives the aggregate activity over APNs and never ends it
    /// itself, so a finishing `update` that is lost — a dropped push, or a
    /// desktop that crashed or quit mid-job — pins the activity on "Working"
    /// forever. This reconciles it against the two truths the device still
    /// holds:
    ///
    ///  - the desktop's mirrored session list, delivered over the live relay:
    ///    a job the activity still calls `running` whose session the desktop
    ///    reports present-and-not-streaming has actually finished — flip it to
    ///    `done`. An absent session is left untouched: the mirror may simply
    ///    be incomplete, which is not evidence the job finished.
    ///  - the relay connection: if the relay is down and the activity has not
    ///    been refreshed within `staleActivityEndThreshold`, the desktop is
    ///    unreachable and the activity can never recover — end it.
    @available(iOS 16.2, *)
    private func reconcileActivities(for sessions: [SessionSummary]) {
        let activities = Activity<RxCodeJobActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let relayConnected: Bool = {
            if case .connected = state?.connectionState { return true }
            return false
        }()
        let now = Date()
        for activity in activities {
            let content = activity.content.state
            // A done activity is a valid terminal state — leave it alone.
            guard content.deduplicatedJobs.contains(where: { $0.phase == .running }) else {
                continue
            }

            // The desktop is unreachable and the activity has gone stale well
            // past any live job's update cadence — it can never recover. End
            // it rather than leave a dead "Working" indicator on screen.
            let age = now.timeIntervalSince1970 - content.updatedAt
            if !relayConnected, age > staleActivityEndThreshold {
                logger.warning("[LiveActivity] ending stalled activity id=\(activity.id, privacy: .public) — relay down, \(Int(age), privacy: .public)s since last desktop update")
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }

            // The desktop is reachable: trust its mirrored session list.
            guard relayConnected else { continue }
            var jobs = content.jobs
            var healed = false
            for idx in jobs.indices where jobs[idx].phase == .running {
                guard let session = sessions.first(where: { $0.id == jobs[idx].id }),
                      !session.isStreaming
                else { continue }
                jobs[idx].phase = .done
                healed = true
            }
            guard healed else { continue }
            let healedState = RxCodeJobActivityAttributes.ContentState(
                jobs: jobs, updatedAt: now.timeIntervalSince1970
            )
            logger.warning("[LiveActivity] healing stalled activity id=\(activity.id, privacy: .public) — desktop's finishing update was lost; marking finished jobs done")
            Task {
                await activity.update(ActivityContent(state: healedState, staleDate: nil))
            }
        }
    }

    /// Ensure at most one Live Activity exists. iOS can still spawn a second
    /// one — the desktop's push-to-start travels over APNs, not the relay, so
    /// it can race a foreground local start when the relay briefly drops — so
    /// whenever the activity set changes, end every extra activity.
    @available(iOS 16.2, *)
    private func endExtraActivities() {
        let activities = Activity<RxCodeJobActivityAttributes>.activities
        guard activities.count > 1 else { return }
        let keepID = activities.first { $0.id == currentActivityID }?.id ?? activities[0].id
        currentActivityID = keepID
        for extra in activities where extra.id != keepID {
            let extraID = extra.id
            logger.warning("[LiveActivity] ending duplicate activity id=\(extraID, privacy: .public) — keeping id=\(keepID, privacy: .public)")
            intentionallyEndedActivityIDs.insert(extraID)
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
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
        if let activityTokenHex, let currentActivityID {
            Task { [weak state] in
                await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                    activityTokenHex: activityTokenHex, activityID: currentActivityID
                ))
            }
        } else if locallyStarted, let currentActivityID {
            // Local start whose per-activity token has not been minted yet —
            // re-assert it so a reconnect still suppresses the push-to-start.
            Task { [weak state] in
                await state?.sendLiveActivityToken(LiveActivityTokenPayload(
                    activityID: currentActivityID, activityStartedLocally: true
                ))
            }
        }
    }
}
#endif
