import Foundation
import RxCodeCore
import Testing
@testable import RxCode

struct PetScheduledReportTests {
    @Test("A progress check never executes before its claim is durable")
    @MainActor
    func failedClaimDoesNotExecute() async throws {
        let persistence = MockAppStatePersistence()
        await persistence.setFailScheduledTaskSaves(true)
        let app = AppState(persistence: persistence, startBackgroundServices: false)
        let pet = PetController()
        app.scheduledPetReportReceiver = pet
        var task = ScheduledTask(name: "Check", prompt: "Observe", cronExpression: "")
        task.reportsPetProgress = true
        task.dueAt = .now.addingTimeInterval(-1)
        app.scheduledTasks = [task]
        app.runDueScheduledTasks(since: .now, now: .now)
        try await waitFor { app.scheduledTaskRuns.first?.status == .failed }
        #expect(app.scheduledTasks[0].lastRunAt == nil)
        #expect(app.scheduledTasks[0].pendingPetReport == nil)
        #expect(pet.alertErrorMessage?.contains("Could not persist") == true)
        #expect(pet.voiceSession == nil)
    }

    @Test("Cancelling a claimed check before its execution prevents the query")
    @MainActor
    func cancelQueuedClaim() async throws {
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        var task = ScheduledTask(name: "Check", prompt: "Observe", cronExpression: "")
        task.reportsPetProgress = true
        task.dueAt = .now.addingTimeInterval(-1)
        app.scheduledTasks = [task]
        app.runDueScheduledTasks(since: .now, now: .now)
        _ = try await app.handlePetSchedule(arguments: .object(["action": .string("cancel"), "id": .string(task.id.uuidString)]), sessionKey: "pet-test")
        try await waitFor { app.scheduledPetChecksInFlight.isEmpty }
        #expect(app.scheduledTasks[0].lastRunAt == nil)
        #expect(app.scheduledTasks[0].pendingPetReport == nil)
        #expect(app.scheduledTaskRuns.isEmpty)
    }

    @Test("One-off times resolve relative duration and explicit local timezone without cron")
    func dueTimes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let relative = try ScheduledDueTime.resolve(now: now, afterSeconds: 120, dueAt: nil, localTime: nil, timeZoneID: "Asia/Hong_Kong")
        #expect(relative == now.addingTimeInterval(120))
        let local = try ScheduledDueTime.resolve(now: now, afterSeconds: nil, dueAt: nil, localTime: "2030-01-02 09:30", timeZoneID: "Asia/Hong_Kong")
        #expect(ISO8601DateFormatter().string(from: local) == "2030-01-02T01:30:00Z")
        #expect(throws: (any Error).self) {
            try ScheduledDueTime.resolve(now: now, afterSeconds: 120, dueAt: "2030-01-02T01:30:00Z", localTime: nil, timeZoneID: "Asia/Hong_Kong")
        }
        #expect(throws: (any Error).self) {
            try ScheduledDueTime.resolve(now: now, afterSeconds: nil, dueAt: nil, localTime: "2030-03-10 02:30", timeZoneID: "America/New_York")
        }
    }

    @Test("One-off schedules retain timezone, survive decoding and stop after a durable claim")
    func schedulePersistence() throws {
        var task = ScheduledTask(name: "Check progress", prompt: "Check progress", cronExpression: "")
        task.dueAt = .now.addingTimeInterval(120)
        task.timeZoneIdentifier = "Asia/Hong_Kong"
        task.reportsPetProgress = true
        let restored = try JSONDecoder().decode(ScheduledTask.self, from: JSONEncoder().encode(task))
        #expect(restored.dueAt == task.dueAt && restored.timeZoneIdentifier == task.timeZoneIdentifier)
        #expect(restored.nextRunDate(after: .distantFuture) == task.dueAt)
        task.claimedAt = .now
        #expect(task.nextRunDate() == nil)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        for key in ["dueAt", "claimedAt", "reportsPetProgress", "timeZoneIdentifier"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(ScheduledTask.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.dueAt == nil && legacy.claimedAt == nil)
    }

    @Test("Overdue one-off progress checks execute once and persist an observed report outbox")
    @MainActor
    func overdueExecutionAndDelivery() async throws {
        let persistence = MockAppStatePersistence()
        let app = AppState(persistence: persistence, startBackgroundServices: false)
        let project = Project(name: "ProgressTest", path: "/tmp/progress-test", gitHubRepo: nil)
        app.projects = [project]
        app.taskBoards[project.id] = TaskBoard()
        let suite = "PetScheduledReports-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = PetConfiguration()
        config.isEnabled = true
        config.proactiveMode = .off
        config.isMuted = true
        config.save(to: defaults)
        let pet = PetController(defaults: defaults)
        app.scheduledPetReportReceiver = pet
        var task = ScheduledTask(projectId: project.id, name: "Check progress", prompt: "Check whether deploy is complete", cronExpression: "")
        task.dueAt = .now.addingTimeInterval(-120)
        task.timeZoneIdentifier = "Asia/Hong_Kong"
        task.reportsPetProgress = true
        app.scheduledTasks = [task]
        app.runDueScheduledTasks(since: .now, now: .now)
        app.runDueScheduledTasks(since: .now, now: .now)
        #expect(!app.scheduledTasks[0].isEnabled)
        try await waitFor { app.scheduledTasks[0].pendingPetReport != nil }
        #expect(app.scheduledTaskRuns.filter { $0.taskId == task.id }.count == 1)
        #expect(app.scheduledTasks[0].pendingPetReport?.contains("ProgressTest") == true)
        #expect(app.scheduledTasks[0].pendingPetReport?.contains("No project action was dispatched") == true)
        #expect(app.sessionStates.isEmpty)
        #expect(pet.voiceSession == nil && pet.queuedProactiveSpeech.isEmpty)
        let saved = await persistence.loadScheduledTasks()
        #expect(saved.first?.pendingPetReport != nil)
        let reopened = AppState(persistence: persistence, startBackgroundServices: false)
        reopened.scheduledPetReportReceiver = pet
        await reopened.loadScheduledTasksFromDisk()
        reopened.runDueScheduledTasks(since: .now, now: .now.addingTimeInterval(3_600))
        #expect(reopened.scheduledPetChecksInFlight.isEmpty)
        #expect(reopened.scheduledTaskRuns.count == 1)
        // A silent-output preference intentionally delivers the caption without opening capture.
        pet.configuration.proactiveMode = .bubbleOnly
        reopened.deliverPendingPetReports(pet: pet)
        reopened.deliverPendingPetReports(pet: pet)
        try await waitFor { reopened.scheduledTasks[0].petReportDeliveredAt != nil }
        #expect(pet.petState.bubble?.text.contains("ProgressTest") == true)
        #expect(pet.voiceSession == nil && pet.announcementTask == nil)
        #expect(reopened.scheduledTasks[0].pendingPetReport == nil)
        pet.bubbleDismissTask?.cancel()
    }

    @Test("Pet schedules use the native proposal and can be cancelled before execution")
    @MainActor
    func scheduleProposalAndCancellation() async throws {
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let project = Project(name: "RxCode", path: "/tmp/rxcode", gitHubRepo: nil)
        app.projects = [project]
        let now = Date.now
        let request = Task { try await app.handlePetSchedule(arguments: .object([
            "project_id": .string(project.id.uuidString), "after_seconds": .number(120),
            "time_zone": .string("Asia/Hong_Kong")
        ]), sessionKey: "pet-test", now: now) }
        try await waitFor { !app.scheduledTaskProposals.isEmpty }
        let proposal = try #require(app.scheduledTaskProposals.first)
        #expect(proposal.dueAt == now.addingTimeInterval(120))
        #expect(proposal.cronExpression.isEmpty && proposal.reportsPetProgress == true)
        app.resolveScheduledTaskProposal(id: proposal.id, with: proposal)
        _ = try await request.value
        _ = try await app.handlePetSchedule(arguments: .object(["action": .string("cancel"), "id": .string(proposal.id.uuidString)]), sessionKey: "pet-test")
        #expect(app.dueScheduledTasks(since: now, now: now.addingTimeInterval(600)).isEmpty)
        let saved = await app.persistence.loadScheduledTasks()
        #expect(saved.first?.isEnabled == false)
        let editing = Task { try await app.handlePetSchedule(arguments: .object([
            "action": .string("edit"), "id": .string(proposal.id.uuidString), "after_seconds": .number(180)
        ]), sessionKey: "pet-test", now: now) }
        try await waitFor { !app.scheduledTaskProposals.isEmpty }
        let edited = try #require(app.scheduledTaskProposals.first)
        #expect(edited.id == proposal.id && edited.dueAt == now.addingTimeInterval(180))
        app.resolveScheduledTaskProposal(id: edited.id, with: edited)
        _ = try await editing.value
        #expect(app.scheduledTasks.first?.isEnabled == true)
    }

    @Test("Projectless reminders save directly, list, edit and cancel without inferring a project")
    @MainActor
    func projectlessReminderLifecycle() async throws {
        let persistence = MockAppStatePersistence()
        let app = AppState(persistence: persistence, startBackgroundServices: false)
        app.projects = [Project(name: "Unrelated", path: "/tmp/unrelated", gitHubRepo: nil)]
        let now = Date.now
        let result = try await app.ideHandleToolCall(name: "ide__pet_schedule", arguments: .object([
            "after_seconds": .number(20), "instructions": .string("hello")
        ]), sessionKey: "pet-test")
        #expect(app.scheduledTaskProposals.isEmpty)
        let response = try #require(JSONSerialization.jsonObject(with: Data(try resultText(result).utf8)) as? [String: Any])
        #expect(response["scheduled"] as? Bool == true)
        let stored = try #require(await persistence.loadScheduledTasks().first)
        #expect(stored.projectId == nil && stored.petScheduleKind == .reminder)
        #expect(stored.dueAt != nil && stored.prompt == "hello")
        #expect(response["id"] as? String == stored.id.uuidString)
        let listed = try await app.handlePetSchedule(arguments: .object(["action": .string("list")]), sessionKey: "pet-test")
        let listText = try resultText(listed)
        #expect(listText.contains(stored.id.uuidString) && listText.contains("reminder"))
        let editing = Task { try await app.handlePetSchedule(arguments: .object([
            "action": .string("edit"), "id": .string(stored.id.uuidString),
            "instructions": .string("Take a short stretch break.")
        ]), sessionKey: "pet-test", now: now) }
        try await waitFor { !app.scheduledTaskProposals.isEmpty }
        let edited = try #require(app.scheduledTaskProposals.first)
        #expect(edited.projectId == nil && edited.petScheduleKind == .reminder)
        #expect(edited.dueAt == stored.dueAt && edited.id == stored.id)
        app.resolveScheduledTaskProposal(id: edited.id, with: edited)
        _ = try await editing.value
        _ = try await app.handlePetSchedule(arguments: .object([
            "action": .string("cancel"), "id": .string(stored.id.uuidString)
        ]), sessionKey: "pet-test")
        #expect(app.dueScheduledTasks(since: now, now: now.addingTimeInterval(60)).isEmpty)
        #expect(await persistence.loadScheduledTasks().first?.isEnabled == false)
        #expect(app.taskBoards.isEmpty && app.sessionStates.isEmpty)
    }

    @Test("Reminder creation propagates a storage failure and removes the unsaved reminder")
    @MainActor
    func reminderSaveFailure() async {
        let persistence = MockAppStatePersistence()
        await persistence.setFailScheduledTaskSaves(true)
        let app = AppState(persistence: persistence, startBackgroundServices: false)
        do {
            _ = try await app.handlePetSchedule(arguments: .object([
                "after_seconds": .number(20), "instructions": .string("hello")
            ]), sessionKey: "pet-test")
            Issue.record("Expected reminder storage to fail")
        } catch {
            #expect((error as NSError).domain == "ScheduledTaskPersistenceTest")
        }
        #expect(app.scheduledTasks.isEmpty && app.scheduledTaskProposals.isEmpty)
        #expect(await persistence.loadScheduledTasks().isEmpty)
    }

    @Test("Projectless reminders execute once after restart and use the caption outbox without project checks")
    @MainActor
    func reminderRestartAndExecution() async throws {
        let persistence = MockAppStatePersistence()
        var task = ScheduledTask(name: "Stretch", prompt: "Time to stretch.", cronExpression: "")
        task.petScheduleKind = .reminder
        task.dueAt = .now.addingTimeInterval(-30)
        task.timeZoneIdentifier = "Asia/Hong_Kong"
        try await persistence.saveScheduledTasks([task])
        let suite = "PetReminder-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = PetConfiguration()
        config.isEnabled = true; config.proactiveMode = .off; config.isMuted = true
        config.save(to: defaults)
        let pet = PetController(defaults: defaults)
        let app = AppState(persistence: persistence, startBackgroundServices: false)
        app.scheduledPetReportReceiver = pet
        await app.loadScheduledTasksFromDisk()
        app.runDueScheduledTasks(since: .now, now: .now)
        app.runDueScheduledTasks(since: .now, now: .now)
        try await waitFor { app.scheduledTasks[0].pendingPetReport != nil }
        #expect(app.scheduledTasks[0].pendingPetReport == task.prompt)
        #expect(app.scheduledTaskRuns.count == 1 && app.scheduledTaskRuns[0].status == .succeeded)
        #expect(app.taskBoards.isEmpty && app.sessionStates.isEmpty)
        #expect(pet.voiceSession == nil && pet.queuedProactiveSpeech.isEmpty)
        let reopened = AppState(persistence: persistence, startBackgroundServices: false)
        reopened.scheduledPetReportReceiver = pet
        await reopened.loadScheduledTasksFromDisk()
        reopened.runDueScheduledTasks(since: .now, now: .now.addingTimeInterval(60))
        #expect(reopened.scheduledPetChecksInFlight.isEmpty)
        pet.configuration.proactiveMode = .bubbleOnly
        reopened.deliverPendingPetReports()
        reopened.deliverPendingPetReports()
        try await waitFor { reopened.scheduledTasks[0].petReportDeliveredAt != nil }
        #expect(pet.petState.bubble?.text == task.prompt)
        #expect(pet.voiceSession == nil && pet.announcementTask == nil)
        pet.bubbleDismissTask?.cancel()
    }

    @Test("A project progress request still requires a project and failures never create schedules")
    @MainActor
    func missingProgressProjectDoesNotSchedule() async throws {
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        do {
            _ = try await app.handlePetSchedule(arguments: .object([
                "kind": .string("progress"), "after_seconds": .number(30)
            ]), sessionKey: "pet-test")
            Issue.record("Progress without a project must fail")
        } catch { }
        #expect(app.scheduledTasks.isEmpty && app.scheduledTaskProposals.isEmpty)
        #expect(await app.persistence.loadScheduledTasks().isEmpty)
    }

    private func resultText(_ result: RxCodeCore.JSONValue) throws -> String {
        guard case .array(let blocks) = result["content"],
              let first = blocks.first, case .string(let text) = first["text"] else {
            throw NSError(domain: "PetReminderTest", code: 1)
        }
        return text
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
}
