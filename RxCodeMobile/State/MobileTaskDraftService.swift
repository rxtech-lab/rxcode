import Foundation
import FoundationModels
import RxCodeCore

/// A reviewed suggestion, never a persisted board item.
struct MobileTaskDraft: Decodable {
    let title: String
    let details: String
    let classification: TaskClassification

    init(title: String, details: String, classification: TaskClassification) {
        self.title = title
        self.details = details
        self.classification = classification
    }

    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case title, details }
        let values = try decoder.container(keyedBy: Keys.self)
        title = try values.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        details = try values.decode(String.self, forKey: .details).trimmingCharacters(in: .whitespacesAndNewlines)
        classification = try TaskClassification(from: decoder)
        guard !title.isEmpty, !details.isEmpty else {
            throw FlowcyError.message("AI returned an empty draft. Try again.")
        }
        try validateClassification()
    }

    func validateClassification() throws {
        var task = ProjectTask(projectId: UUID(), title: title)
        classification.apply(to: &task, board: TaskBoard())
        guard task.priority != nil, task.size != nil else {
            throw FlowcyError.message("AI did not provide a valid priority and size. Try again.")
        }
    }

    static func parse(_ text: String) throws -> Self {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw FlowcyError.message("AI returned an invalid draft. Try again.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(text[start...end].utf8))
    }
}

@Generable
private enum OnDeviceTaskPriority: String {
    case urgent, high, medium, low
}

@Generable
private enum OnDeviceTaskSize: String {
    case xs, s, m, l, xl
}

@Generable
private struct OnDeviceTaskDraft {
    var title: String
    var details: String
    var type: String?
    var priority: OnDeviceTaskPriority
    var size: OnDeviceTaskSize
    var version: String?
    var milestone: String?
    var tags: [String]
    var deadline: String?
    var delays: [String]
    var story: String?
    var startsAfter: String?
}

@MainActor
enum MobileTaskDraftService {
    static var onDeviceUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): "Enable Apple Intelligence in Settings to use the on-device model."
        case .unavailable(.modelNotReady): "The on-device model is still downloading. Try again later."
        case .unavailable: "Apple Intelligence is unavailable on this device."
        }
    }

    static func prompt(source: String, board: TaskBoard, kind: ProjectCloudService.DraftKind,
                       storyTitle: String?, candidates: [String]) -> String {
        let classification = TaskClassification.prompt(title: source, details: "", storyTitle: storyTitle, board: board,
                                                       isStory: kind == .story, startsAfterCandidates: candidates)
            .replacingOccurrences(of: #"{"type": string|null"#, with: #"{"title": string, "details": string, "type": string|null"#)
        return """
        Draft a software \(kind.rawValue) from the request below. Return ONLY one JSON object.
        Include title (a concise imperative title) and details (a Markdown description with acceptance criteria),
        as well as the classification fields below in the SAME object. Preserve explicit requirements.
        Use English for generated text. Do not save anything or call tools.

        \(classification)
        """
    }

    static func onDevice(prompt: String) async throws -> MobileTaskDraft {
        if let reason = onDeviceUnavailableReason { throw FlowcyError.message(reason) }
        let session = LanguageModelSession(instructions: "You draft software board items and classify the work. Never invent deadlines or dependencies.")
        let result = try await session.respond(to: prompt, generating: OnDeviceTaskDraft.self).content
        try Task.checkCancellation()
        guard !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FlowcyError.message("AI returned an empty draft. Try again.")
        }
        let draft = MobileTaskDraft(title: result.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               details: result.details.trimmingCharacters(in: .whitespacesAndNewlines),
                               classification: TaskClassification(type: result.type, priority: result.priority.rawValue,
                                   tags: result.tags, version: result.version, milestone: result.milestone,
                                   story: result.story, startsAfter: result.startsAfter,
                                   deadline: result.deadline, size: result.size.rawValue, delays: result.delays))
        try draft.validateClassification()
        return draft
    }

    static func flowcy(prompt: String, api: FlowcyAPI) async throws -> MobileTaskDraft {
        // No tool declarations: generation cannot mutate the board.
        let (bytes, response) = try await api.request(path: "agent/chat", body: .object([
            "messages": .array([.object(["role": .string("user"), "content": .string(prompt)])]),
            "tools": .array([])
        ]))
        guard response.value(forHTTPHeaderField: "Content-Type")?.contains("application/x-ndjson") == true else {
            throw FlowcyError.protocolError
        }
        var text = ""
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty { continue }
            guard line.utf8.count <= 100_000, !finished else { throw FlowcyError.protocolError }
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            switch event["type"]?.stringValue {
            case "text": text += event["text"]?.stringValue ?? ""
            case "finish": finished = true
            case "error": throw FlowcyError.message("Could not generate a draft. Try again.")
            default: throw FlowcyError.protocolError
            }
            guard text.utf8.count <= 100_000 else { throw FlowcyError.protocolError }
        }
        guard finished else { throw FlowcyError.message("The draft was interrupted. Try again.") }
        return try MobileTaskDraft.parse(text)
    }
}
