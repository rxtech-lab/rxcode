import Testing
import RxCodeCore

/// Tests for the aggregate Live Activity job-tracking state machine — the
/// logic that decides which jobs the Live Activity shows and whether each is
/// running or done. Covers the five lifecycle scenarios that previously
/// produced stale "in progress" / wrong "all done" states.
@Suite("Job activity tracker — Live Activity job state")
struct JobActivityTrackerTests {

    // MARK: - Helpers

    /// Build job content the way `MobileSyncService.makeJobContent` does: a
    /// non-streaming session is `done`, and a done session with no pending
    /// unread flag counts as `read`.
    private func content(
        _ id: String,
        streaming: Bool,
        unread: Bool = false,
        title: String = "Job",
        done: Int = 0,
        total: Int = 0,
        step: String? = nil
    ) -> JobContent {
        let isDone = !streaming
        return JobContent(
            sessionID: id, title: title, projectName: "Proj",
            todoDone: done, todoTotal: total, currentStep: step,
            isDone: isDone, isRead: isDone && !unread
        )
    }

    /// A `.streamingStarted` update — the session begins a turn.
    @discardableResult
    private func start(
        _ t: inout JobActivityTracker, _ id: String, title: String = "Job"
    ) -> JobActivityTracker.IngestResult {
        t.ingest(sessionID: id, content: content(id, streaming: true, title: title),
                 streamingOverride: true, previousSessionID: nil)
    }

    /// A `.streamingFinished` update. `unread` mirrors a background completion
    /// the user has not opened yet; the default is a foreground finish.
    @discardableResult
    private func finish(
        _ t: inout JobActivityTracker, _ id: String, unread: Bool = false, title: String = "Job"
    ) -> JobActivityTracker.IngestResult {
        t.ingest(sessionID: id, content: content(id, streaming: false, unread: unread, title: title),
                 streamingOverride: false, previousSessionID: nil)
    }

    /// A `.statusChanged` update — progress, title summarization, read flips.
    @discardableResult
    private func status(
        _ t: inout JobActivityTracker, _ id: String, streaming: Bool,
        unread: Bool = false, title: String = "Job", done: Int = 0, total: Int = 0
    ) -> JobActivityTracker.IngestResult {
        t.ingest(
            sessionID: id,
            content: content(id, streaming: streaming, unread: unread, title: title, done: done, total: total),
            streamingOverride: streaming, previousSessionID: nil
        )
    }

    private func ids(_ t: JobActivityTracker) -> [String] { t.trackedJobs.map(\.sessionID) }
    private func job(_ t: JobActivityTracker, _ id: String) -> JobContent? {
        t.trackedJobs.first { $0.sessionID == id }
    }

    // MARK: - 1. Continue on the same thread

    @Test("1. Continuing the same thread revives a finished job")
    func continueSameThread() {
        var t = JobActivityTracker()
        start(&t, "A")
        #expect(job(t, "A")?.isDone == false)

        finish(&t, "A")
        #expect(job(t, "A")?.isDone == true)
        #expect(job(t, "A")?.isRead == true)
        #expect(t.allJobsDone)

        // A follow-up turn in the same thread must bring the job back to life.
        let resumed = start(&t, "A")
        #expect(t.trackedJobs.count == 1)
        #expect(job(t, "A")?.isDone == false)
        #expect(t.allJobsDone == false, "A resumed job must not report all-done")
        #expect(resumed.resumedWork, "Resuming after all-done must trigger an immediate push")
    }

    @Test("A read+done job is frozen against post-completion churn")
    func readJobFrozenAgainstChurn() {
        var t = JobActivityTracker()
        start(&t, "A", title: "Old title")
        finish(&t, "A", title: "Old title")

        // A late title-summarization status update for the finished job: a
        // read+done job must stay frozen and generate no further change.
        let r = status(&t, "A", streaming: false, title: "AI summarized title")
        #expect(job(t, "A")?.title == "Old title")
        #expect(r.jobsChanged == false)
    }

    @Test("A background-finished job can still flip to read")
    func backgroundFinishedBecomesRead() {
        var t = JobActivityTracker()
        start(&t, "A")
        finish(&t, "A", unread: true)
        #expect(job(t, "A")?.isDone == true)
        #expect(job(t, "A")?.isRead == false)

        // The user opens the thread → desktop rebroadcasts with the flag cleared.
        status(&t, "A", streaming: false, unread: false)
        #expect(job(t, "A")?.isRead == true)
        #expect(job(t, "A")?.isDone == true)
    }

    // MARK: - 2. New thread

    @Test("2. A new thread clears the finished, acknowledged batch")
    func newThread() {
        var t = JobActivityTracker()
        start(&t, "A")
        finish(&t, "A")
        #expect(ids(t) == ["A"])

        let r = start(&t, "B")
        #expect(ids(t) == ["B"])
        #expect(job(t, "B")?.isDone == false)
        #expect(t.allJobsDone == false)
        #expect(r.batchReset)
        #expect(r.resumedWork, "A new job after the all-done batch must push immediately")
    }

    // MARK: - 3. Multiple threads

    @Test("3. Multiple concurrent threads are all tracked")
    func multipleThreads() {
        var t = JobActivityTracker()
        start(&t, "A")
        start(&t, "B")
        start(&t, "C")
        #expect(ids(t) == ["A", "B", "C"])
        #expect(t.streamingSessionIDs == ["A", "B", "C"])
        let noneDone = t.trackedJobs.allSatisfy { !$0.isDone }
        #expect(noneDone)
        #expect(t.allJobsDone == false)
    }

    // MARK: - 4. All stops

    @Test("4. All threads stopping reports every job done")
    func allStop() {
        var t = JobActivityTracker()
        start(&t, "A")
        start(&t, "B")
        finish(&t, "A")
        finish(&t, "B")
        #expect(ids(t) == ["A", "B"])
        #expect(t.allJobsDone)
        #expect(t.streamingSessionIDs.isEmpty)
    }

    // MARK: - 5. Partial stops

    @Test("5. A partial stop keeps the still-running job active")
    func partialStop() {
        var t = JobActivityTracker()
        start(&t, "A")
        start(&t, "B")
        finish(&t, "A")
        #expect(job(t, "A")?.isDone == true)
        #expect(job(t, "B")?.isDone == false)
        #expect(t.allJobsDone == false, "B is still running")
        #expect(t.streamingSessionIDs == ["B"])

        // B keeps emitting progress — A must stay done, B stays running.
        status(&t, "B", streaming: true, done: 2, total: 5)
        #expect(job(t, "A")?.isDone == true)
        #expect(job(t, "B")?.isDone == false)
        #expect(job(t, "B")?.todoTotal == 5)
        #expect(t.allJobsDone == false)
    }

    // MARK: - Resumed work (immediate push)

    @Test("Resuming work after every job finished signals an immediate push")
    func resumedWorkSignalsImmediatePush() {
        var t = JobActivityTracker()
        start(&t, "A")
        finish(&t, "A")

        // A new job started after the all-done batch.
        let newJob = start(&t, "B")
        #expect(newJob.resumedWork)

        finish(&t, "B")
        // The same thread resuming after the all-done batch.
        let resumed = start(&t, "B")
        #expect(resumed.resumedWork)
    }

    @Test("Ordinary start, progress and finish updates do not signal resumed work")
    func ordinaryUpdatesDoNotResumeWork() {
        var t = JobActivityTracker()
        let first = start(&t, "A")
        #expect(first.resumedWork == false, "The very first job is not a resume")

        let progress = status(&t, "A", streaming: true, done: 1, total: 3)
        #expect(progress.resumedWork == false)

        let done = finish(&t, "A")
        #expect(done.resumedWork == false)
    }

    // MARK: - Capacity

    @Test("The tracked list is capped, dropping the oldest job first")
    func pruneCapsList() {
        var t = JobActivityTracker()
        for i in 0..<(JobActivityTracker.cap + 1) { start(&t, "J\(i)") }
        #expect(t.trackedJobs.count == JobActivityTracker.cap)
        #expect(ids(t).contains("J0") == false, "The oldest job is dropped to honor the cap")
    }
}
