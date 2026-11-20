import Foundation
import os
import RxCodeCore

extension AppState {
    @MainActor
    func handleGetStories(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let projectId = try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        await ensureTaskBoardLoaded(for: projectId)
        let board = taskBoard(for: projectId)
        let rollups = board.storyRollups()
        return jsonTextResult(.array(board.stories.map { story in
            var obj = storyJSON(story)
            if let rollup = rollups[story.id] {
                obj["status"] = .string(rollup.status.rawValue)
                obj["tasks_done"] = .number(Double(rollup.progress.done))
                obj["tasks_total"] = .number(Double(rollup.progress.total))
            }
            return .object(obj)
        }))
    }

    private func storyJSON(_ story: ProjectStory) -> [String: JSONValue] {
        [
            "id": .string(story.id.uuidString),
            "project_id": .string(story.projectId.uuidString),
            "title": .string(story.title),
            "details": .string(story.details),
            "linked_project_ids": .array(story.linkedProjectIds.map { .string($0.uuidString) }),
        ]
    }

    private func parseProjectIdList(_ value: JSONValue?, field: String) throws -> [UUID] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw IDEToolError.invalidArguments("\(field) must be an array of project UUIDs.")
        }
        return try array.map { entry in
            guard let raw = entry.stringValue, let id = UUID(uuidString: raw),
                  projects.contains(where: { $0.id == id })
            else {
                throw IDEToolError.invalidArguments("\(field) contains an unknown project id. Call ide__get_projects first.")
            }
            return id
        }
    }

    @MainActor
    func handleCreateStory(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let projectId = try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw IDEToolError.invalidArguments("A nonempty title is required.")
        }
        let linked = try parseProjectIdList(arguments["linked_project_ids"], field: "linked_project_ids")
        await ensureTaskBoardLoaded(for: projectId)
        let story = ProjectStory(projectId: projectId, title: title, details: arguments["details"]?.stringValue ?? "")
        upsertStory(story)
        let result = linked.isEmpty
            ? story
            : await linkStory(story.id, in: projectId, to: linked) ?? story
        return jsonTextResult(.object(storyJSON(result)))
    }

    @MainActor
    func handleLinkStory(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        guard let raw = arguments["story_id"]?.stringValue, let storyId = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("A valid story_id is required.")
        }
        let link = try parseProjectIdList(arguments["link_project_ids"], field: "link_project_ids")
        let unlink = try parseProjectIdList(arguments["unlink_project_ids"], field: "unlink_project_ids")
        guard !link.isEmpty || !unlink.isEmpty else {
            throw IDEToolError.invalidArguments("Pass link_project_ids or unlink_project_ids.")
        }
        guard Set(link).isDisjoint(with: unlink) else {
            throw IDEToolError.invalidArguments("A project cannot be both linked and unlinked.")
        }
        await ensureAllTaskBoardsLoaded()
        // The story's own board: the explicit or current project when it holds
        // the story, otherwise any board that does.
        let preferred = try? taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        guard let projectId = [preferred].compactMap({ $0 }).first(where: { taskBoard(for: $0).story(id: storyId) != nil })
                ?? taskBoards.first(where: { $0.value.story(id: storyId) != nil })?.key
        else {
            throw IDEToolError.invalidArguments("story_id must identify an existing story.")
        }

        var story = taskBoard(for: projectId).story(id: storyId)
        if !link.isEmpty {
            story = await linkStory(storyId, in: projectId, to: link)
        }
        if !unlink.isEmpty {
            // Unlinking the anchor board itself still leaves the story on the
            // remaining boards, so read the result back from one of those.
            story = unlinkStory(storyId, in: projectId, from: unlink)
        }
        guard let story else {
            return textResult("Story \(storyId.uuidString) is no longer on any project board.")
        }
        return jsonTextResult(.object(storyJSON(story)))
    }
}
