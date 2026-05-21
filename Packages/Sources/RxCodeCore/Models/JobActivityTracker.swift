import Foundation

/// Latest content the desktop knows for one job in the aggregate Live
/// Activity. Stored in `JobActivityTracker.trackedJobs` in start order.
public struct JobContent: Sendable, Equatable {
    public var sessionID: String
    public var title: String
    public var projectName: String
    public var todoDone: Int
    public var todoTotal: Int
    public var currentStep: String?
    /// `true` once the job has finished. It shows the "done" phase but stays
    /// in the aggregate list so the activity can report the completed batch.
    public var isDone: Bool
    /// `true` once the job has finished and the user has viewed it. A read job
    /// is frozen — later summaries no longer mutate the tracked entry, so an
    /// acknowledged job stops generating Live Activity pushes while staying
    /// visible. Deliberately excluded from `signature`: a read-state flip
    /// alone must never trigger a push.
    public var isRead: Bool

    public init(
        sessionID: String,
        title: String,
        projectName: String,
        todoDone: Int,
        todoTotal: Int,
        currentStep: String?,
        isDone: Bool,
        isRead: Bool
    ) {
        self.sessionID = sessionID
        self.title = title
        self.projectName = projectName
        self.todoDone = todoDone
        self.todoTotal = todoTotal
        self.currentStep = currentStep
        self.isDone = isDone
        self.isRead = isRead
    }

    /// Identifies a distinct rendered state for one job, so an update only
    /// pushes on a real change rather than on every session event. Includes
    /// `title` so the activity refreshes when the desktop swaps in an
    /// AI-summarized title. `isRead` is intentionally excluded.
    public var signature: String {
        "\(sessionID)|\(isDone ? "done" : "run")|\(title)|\(todoDone)/\(todoTotal)|\(currentStep ?? "")"
    }
}

/// Pure, testable state machine behind the aggregate Live Activity. Owns the
/// tracked-job list and the set of streaming sessions, and folds session
/// updates into them. Holds no networking or scheduling — `MobileSyncService`
/// wraps it and performs the throttled APNs pushes on top.
public struct JobActivityTracker: Sendable {
    /// Every job tracked by the single aggregate Live Activity: those still
    /// running plus recently finished ones, in start order.
    public private(set) var trackedJobs: [JobContent] = []
    /// Session ids currently streaming — the live job count for the widget.
    public private(set) var streamingSessionIDs: Set<String> = []

    /// Maximum jobs retained before the oldest finished ones are dropped, so a
    /// long-lived device never accumulates an unbounded history.
    public static let cap = 6

    public init() {}

    /// Concatenated per-job signatures — identifies a distinct rendered state.
    public var jobsSignature: String {
        trackedJobs.map(\.signature).joined(separator: ";")
    }

    /// `true` once every tracked job has finished.
    public var allJobsDone: Bool {
        !trackedJobs.isEmpty && trackedJobs.allSatisfy(\.isDone)
    }

    /// Outcome of folding one session update into the tracker.
    public struct IngestResult: Equatable, Sendable {
        /// The tracked-job list changed — the Live Activity may need a push.
        public var jobsChanged: Bool
        /// A finished batch was cleared or a job was re-keyed: the caller must
        /// reset its last-pushed signature so the next push is forced out.
        public var batchReset: Bool
        /// The activity went from every job finished to a job running again.
        /// The caller should push immediately, bypassing the update throttle,
        /// so the Live Activity wakes up at once instead of a window later.
        public var resumedWork: Bool
    }

    /// Fold one session update into the job set, mirroring the desktop's
    /// `updateJobTracking`:
    ///
    /// - A previously-tracked session that re-keys (`previousSessionID`) is
    ///   moved to the new id, or dropped when no content is supplied.
    /// - The streaming set follows `streamingOverride` when given.
    /// - A running session is inserted or updated; a finished session updates
    ///   an existing entry only. When a new job starts while every tracked job
    ///   is already done, the previous (acknowledged) batch is cleared.
    /// - A finished job the user has already read is frozen — later non-
    ///   streaming updates for it are ignored, but a fresh stream revives it.
    @discardableResult
    public mutating func ingest(
        sessionID: String,
        content: JobContent?,
        streamingOverride: Bool?,
        previousSessionID: String?
    ) -> IngestResult {
        var jobsChanged = false
        var batchReset = false
        // Captured before folding so a complete → running transition can be
        // reported back to the caller for an immediate, un-throttled push.
        let wasAllDone = allJobsDone

        if let previousSessionID, previousSessionID != sessionID {
            streamingSessionIDs.remove(previousSessionID)
            if let prevIdx = trackedJobs.firstIndex(where: { $0.sessionID == previousSessionID }) {
                if let content {
                    trackedJobs[prevIdx] = content
                } else {
                    trackedJobs.remove(at: prevIdx)
                }
                jobsChanged = true
                batchReset = true
            }
        }

        if let streamingOverride {
            if streamingOverride {
                streamingSessionIDs.insert(sessionID)
            } else {
                streamingSessionIDs.remove(sessionID)
            }
        }

        if let content {
            if let idx = trackedJobs.firstIndex(where: { $0.sessionID == content.sessionID }) {
                // A finished job the user has already viewed is frozen: keep it
                // exactly as last rendered while it stays non-streaming. The
                // freeze lifts the instant the session streams again, so a
                // follow-up turn brings the job back to "running".
                let frozen = trackedJobs[idx].isDone
                    && trackedJobs[idx].isRead
                    && content.isDone
                if !frozen, trackedJobs[idx] != content {
                    trackedJobs[idx] = content
                    jobsChanged = true
                }
            } else if !content.isDone {
                // A new running job. If every tracked job is already finished,
                // clear that acknowledged batch so the activity starts fresh.
                if !trackedJobs.isEmpty, trackedJobs.allSatisfy(\.isDone) {
                    trackedJobs.removeAll()
                    batchReset = true
                }
                trackedJobs.append(content)
                jobsChanged = true
            }
            if prune() { jobsChanged = true }
        }

        return IngestResult(
            jobsChanged: jobsChanged,
            batchReset: batchReset,
            resumedWork: wasAllDone && !allJobsDone
        )
    }

    /// Cap the tracked-job list, dropping the oldest finished jobs first.
    /// Returns `true` when anything was removed.
    @discardableResult
    private mutating func prune() -> Bool {
        var removed = false
        while trackedJobs.count > Self.cap {
            if let doneIdx = trackedJobs.firstIndex(where: \.isDone) {
                trackedJobs.remove(at: doneIdx)
            } else {
                trackedJobs.removeFirst()
            }
            removed = true
        }
        return removed
    }
}
