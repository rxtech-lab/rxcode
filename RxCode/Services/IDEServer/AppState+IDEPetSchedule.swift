import Foundation
import RxCodeCore

extension AppState {
    func handlePetSchedule(arguments: JSONValue, sessionKey: String, now: Date = .now) async throws -> JSONValue {
        let action = arguments["action"]?.stringValue ?? "schedule"
        if action == "list" {
            return jsonTextResult(.array(scheduledTasks.filter { $0.isPetSchedule }.map { task in
                .object(["id": .string(task.id.uuidString), "name": .string(task.name),
                    "project_id": task.projectId.map { .string($0.uuidString) } ?? .null,
                    "kind": .string(task.resolvedPetScheduleKind?.rawValue ?? "progress"),
                    "instructions": .string(task.prompt), "enabled": .bool(task.isEnabled),
                    "due_at": task.dueAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                    "time_zone": .string(task.timeZoneIdentifier ?? TimeZone.current.identifier),
                    "has_pending_report": .bool(task.pendingPetReport != nil),
                    "claimed": .bool(task.claimedAt != nil), "executed": .bool(task.lastRunAt != nil)])
            }))
        }
        if action == "cancel" {
            guard let raw = arguments["id"]?.stringValue, let id = UUID(uuidString: raw),
                  let index = scheduledTasks.firstIndex(where: { $0.id == id && $0.isPetSchedule }) else {
                throw IDEToolError.invalidArguments("No pet schedule with this id. Call action=list first.")
            }
            scheduledTasks[index].isEnabled = false
            if scheduledTasks[index].lastRunAt == nil { scheduledTasks[index].claimedAt = nil }
            scheduledTasks[index].pendingPetReport = nil
            (scheduledPetReportReceiver ?? .shared).cancelScheduledReport(id: id)
            scheduledTasks[index].updatedAt = now
            try await persistScheduledTasks()
            return textResult("Cancelled future execution of \(id). A check or spoken report already started cannot be retracted.")
        }
        guard action == "schedule" || action == "edit" else { throw IDEToolError.invalidArguments("action must be schedule, edit, list or cancel.") }
        var previous: ScheduledTask?
        if action == "edit" {
            guard let id = arguments["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let existing = scheduledTasks.first(where: { $0.id == id && $0.isPetSchedule
                      && !scheduledPetChecksInFlight.contains($0.id) && $0.pendingPetReport == nil
                      && ($0.dueAt == nil || ($0.claimedAt == nil && $0.lastRunAt == nil)) }) else {
                throw IDEToolError.invalidArguments("Only an unclaimed pet schedule can be edited. List tasks first.")
            }
            previous = existing
        }
        let requestedKind = arguments["kind"]?.stringValue
        if let requestedKind, PetScheduleKind(rawValue: requestedKind) == nil {
            throw IDEToolError.invalidArguments("kind must be reminder or progress.")
        }
        // Omission on a new request means a general reminder, never the active/pinned project.
        // Edits keep their previous kind and association unless explicitly changed.
        let kind = requestedKind.flatMap(PetScheduleKind.init(rawValue:))
            ?? previous?.resolvedPetScheduleKind
            ?? (arguments["project_id"]?.stringValue == nil ? .reminder : .progress)
        let projectID: UUID?
        if kind == .progress {
            projectID = try parseOptionalProjectId(arguments["project_id"]?.stringValue) ?? previous?.projectId
            guard let projectID, projects.contains(where: { $0.id == projectID }) else {
                throw IDEToolError.invalidArguments("A progress check requires an explicit project_id. Resolve the named project with ide__get_projects. For a general reminder, omit project_id and use kind=reminder.")
            }
        } else {
            guard arguments["project_id"]?.stringValue == nil else {
                throw IDEToolError.invalidArguments("General reminders have no project. Omit project_id, or use kind=progress for an actual project check.")
            }
            projectID = nil
        }
        let zone = arguments["time_zone"]?.stringValue ?? previous?.timeZoneIdentifier ?? TimeZone.current.identifier
        guard TimeZone(identifier: zone) != nil else { throw IDEToolError.invalidArguments("time_zone must be an IANA timezone.") }
        let name = arguments["name"]?.stringValue ?? previous?.name ?? (kind == .reminder ? "Reminder" : "Scheduled progress report")
        let instructions = arguments["instructions"]?.stringValue ?? previous?.prompt ?? (kind == .reminder ? "" : "Check current project tasks and threads and report observed progress.")
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("Provide the reminder text in instructions.")
        }
        var proposal = ScheduledTask(id: previous?.id ?? UUID(), projectId: projectID, name: name,
                                     prompt: instructions, cronExpression: arguments["cron_expression"]?.stringValue ?? "")
        proposal.timeZoneIdentifier = zone
        proposal.petScheduleKind = kind
        proposal.reportsPetProgress = kind == .progress
        proposal.createdAt = previous?.createdAt ?? now
        let hasNewTime = ["after_seconds", "due_at", "local_time", "cron_expression"].contains { arguments[$0] != nil }
        if !hasNewTime, let previous {
            proposal.dueAt = previous.dueAt
            proposal.cronExpression = previous.cronExpression
        } else if !proposal.cronExpression.isEmpty {
            guard arguments["after_seconds"] == nil && arguments["due_at"] == nil && arguments["local_time"] == nil else {
                throw IDEToolError.invalidArguments("Use a cron schedule OR one one-off time, not both.")
            }
            do { _ = try CronExpression(proposal.cronExpression) }
            catch { throw IDEToolError.invalidArguments("Invalid cron_expression.") }
        } else {
            do {
                proposal.dueAt = try ScheduledDueTime.resolve(now: now,
                    afterSeconds: arguments["after_seconds"]?.numberValue,
                    dueAt: arguments["due_at"]?.stringValue, localTime: arguments["local_time"]?.stringValue, timeZoneID: zone)
            } catch {
                throw IDEToolError.invalidArguments("Provide one future time: after_seconds (e.g. 120 for two minutes), due_at (ISO8601 with offset), or local_time (yyyy-MM-dd HH:mm) and time_zone. Invalid/nonexistent local times are rejected.")
            }
        }
        let added: ScheduledTask
        if action == "schedule" && kind == .reminder {
            added = proposal
            scheduledTasks.append(added)
            do {
                try await persistScheduledTasks()
            } catch {
                scheduledTasks.removeAll { $0.id == added.id }
                throw error
            }
            AnalyticsService.shared.log(.scheduledTaskCreated)
        } else {
            guard let confirmed = await confirmScheduledTaskProposal(proposal) else {
                return textResult("The user cancelled the schedule proposal.")
            }
            added = confirmed
            try await persistScheduledTasks()
        }
        return jsonTextResult(.object(["id": .string(added.id.uuidString), "scheduled": .bool(true),
            "due_at": added.nextRunDate().map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "kind": .string(added.resolvedPetScheduleKind?.rawValue ?? kind.rawValue), "project_id": added.projectId.map { .string($0.uuidString) } ?? .null,
            "time_zone": .string(zone), "one_off": .bool(added.dueAt != nil),
            "behavior": .string((kind == .reminder ? "Delivers the saved reminder text when due without checking any project or dispatching an agent, then queues" : "Queries actual project status when due, then queues") + " a caption/spoken report according to pet notification preferences. Does not open a microphone or call. Overdue one-offs run once after launch/wake. An interrupted claimed check is reported as interrupted, not silently rerun.")]))
    }
}
