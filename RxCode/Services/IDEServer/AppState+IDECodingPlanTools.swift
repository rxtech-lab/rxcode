import Foundation
import RxCodeCore

extension AppState {
    func handleCodingPlanTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        func uuid(_ key: String) throws -> UUID {
            guard let raw = arguments[key]?.stringValue, let value = UUID(uuidString: raw) else {
                throw IDEToolError.invalidArguments("Pass a UUID for '\(key)'.")
            }
            return value
        }
        func integer(_ key: String, default fallback: Int) throws -> Int {
            guard let argument = arguments[key] else { return fallback }
            guard let n = argument.numberValue, let value = Int(exactly: n) else {
                throw IDEToolError.invalidArguments("Pass an integer for '\(key)'.")
            }
            return value
        }
        let project = try arguments["project_id"].map { _ in try uuid("project_id") }
        let limit = try integer("limit", default: 20)
        let offset = try integer("offset", default: 0)
        guard (1...50).contains(limit), offset >= 0 else {
            throw IDEToolError.invalidArguments("Pass a nonnegative offset and a limit between 1 and 50.")
        }
        let iso = ISO8601DateFormatter()
        func page(_ key: String, entries: [JSONValue], count: Int) -> JSONValue {
            let end = min(offset, count) + entries.count
            return .object([key: .array(entries), "total": .number(Double(count)),
                            "next_offset": end < count ? .number(Double(end)) : .null])
        }

        if name == "ide__list_coding_plans" {
            let thread = arguments["thread_id"]?.stringValue
            if arguments["thread_id"] != nil && (thread ?? "").isEmpty {
                throw IDEToolError.invalidArguments("Pass a nonempty string for 'thread_id'.")
            }
            let plans = try await codingPlanActivities(projectID: project, threadID: thread)
            let entries = plans.dropFirst(offset).prefix(limit).map { planJSON($0, iso: iso) }
            return jsonTextResult(page("plans", entries: entries, count: plans.count))
        }
        let planID = try uuid("plan_id")
        let matches = try await readCodingPlans(projectID: project, threadID: planID.uuidString)
        guard let record = matches.first(where: { $0.activity.id == planID }) else {
            throw IDEToolError.invalidArguments("No coding plan with ID \(planID).")
        }
        let activity = record.activity
        func versionJSON(_ i: Int) -> [String: JSONValue] {
            let version = record.versions[i]
            return ["version_id": .string(version.id.uuidString), "number": .number(Double(i + 1)),
                    "title": .string(version.title), "created_at": version.createdAt.map { .string(iso.string(from: $0)) } ?? .null,
                    "is_current": .bool(version.id == activity.currentVersionID), "is_approved": .bool(version.id == activity.approvedVersionID)]
        }
        let metadata = planJSON(activity, iso: iso)
        if name == "ide__list_coding_plan_versions" {
            let entries = record.versions.indices.reversed().dropFirst(offset).prefix(limit).map { JSONValue.object(versionJSON($0)) }
            var response = page("versions", entries: entries, count: record.versions.count).objectValue ?? [:]
            response["plan"] = metadata
            return jsonTextResult(.object(response))
        }
        let versionID = try uuid("version_id")
        guard let i = record.versions.firstIndex(where: { $0.id == versionID }) else {
            throw IDEToolError.invalidArguments("Coding plan \(planID) has no version with ID \(versionID).")
        }
        var version = versionJSON(i)
        version["markdown"] = .string(record.versions[i].markdown)
        return jsonTextResult(.object(["plan": metadata, "version": .object(version)]))
    }

    private func planJSON(_ plan: CodingPlanActivity, iso: ISO8601DateFormatter) -> JSONValue {
        .object([
            "plan_id": .string(plan.id.uuidString), "thread_id": .string(plan.threadID), "project_id": .string(plan.projectID.uuidString),
            "title": .string(plan.title), "goal": .string(plan.goal), "branch": plan.branch.map(JSONValue.string) ?? .null,
            "created_at": .string(iso.string(from: plan.createdAt)), "updated_at": .string(iso.string(from: plan.updatedAt)),
            "planning_status": .string(plan.planningStatus), "implementation_status": .string(plan.implementationStatus),
            "implementation_evidence": .string(plan.implementationEvidence),
            "implementation_thread_id": plan.implementationThreadID.map(JSONValue.string) ?? .null,
            "implementation_thread_ids": .array(plan.linkedImplementationIDs.map(JSONValue.string)),
            "current_version_id": plan.currentVersionID.map { .string($0.uuidString) } ?? .null,
            "current_version_title": plan.currentVersionTitle.map(JSONValue.string) ?? .null,
            "approved_version_title": plan.approvedVersionTitle.map(JSONValue.string) ?? .null,
            "approved_version_id": plan.approvedVersionID.map { .string($0.uuidString) } ?? .null,
            "version_count": .number(Double(plan.versionCount)), "feature_excerpt": .string(plan.featureExcerpt)
        ])
    }
}
