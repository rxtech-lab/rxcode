import Foundation
import RxCodeCore

extension ACPService {
    enum SteeringOutcome: Equatable, Sendable {
        case injected
        case declined
        case unconfirmed
    }

    struct SteeringRequest {
        let id: Int
        let message: ChatMessage
        let reply: CheckedContinuation<SteeringOutcome, Never>
        let timer: Task<Void, Never>
        var promptCompletion: CheckedContinuation<Void, Never>?
        var updates: [JSONValue] = []
    }

    static func supportsHostOwnedSteering(_ initializeResult: JSONValue) -> Bool {
        guard initializeResult["protocolVersion"]?.intValue == 1,
              initializeResult["_meta"]?["steering"]?["supported"] == .bool(true),
              let name = initializeResult["agentInfo"]?["name"]?.stringValue,
              let version = initializeResult["agentInfo"]?["version"]?.stringValue,
              ACPPackageVersion.isValid(version),
              let release = version.split(separator: "+").first, !release.contains("-")
        else { return false }

        // The capability alone also describes older adapters that may start a
        // detached turn. Require the releases that support a host-owned fallback
        // and keep an injected steer within the prompt lifecycle.
        switch name {
        case "@agentclientprotocol/codex-acp":
            return release.hasPrefix("2.") && release.compare("2.4.0", options: .numeric) != .orderedAscending
        case "@agentclientprotocol/claude-agent-acp":
            return release.hasPrefix("0.") && release.compare("0.65.0", options: .numeric) != .orderedAscending
        default:
            return false
        }
    }

    func steer(streamId: UUID, prompt: String, message: ChatMessage) async -> SteeringOutcome {
        guard let key = streamToKey[streamId], let entry = sessions[key],
              entry.currentStreamId == streamId, let sessionId = entry.agentSessionId,
              entry.acceptingUpdates, entry.supportsHostOwnedSteering, !entry.cancellationRequested,
              entry.steering == nil, !Task.isCancelled else { return .declined }

        let id = nextRequestId(key: key)
        return await withCheckedContinuation { reply in
            let timer = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, sessions[key]?.generation == entry.generation,
                      sessions[key]?.steering?.id == id else { return }
                finishSteering(key: key, outcome: .unconfirmed)
            }
            mutateSession(key) { $0.steering = SteeringRequest(id: id, message: message, reply: reply, timer: timer) }
            do {
                try writeFrame(key: key, frame: .object([
                    "jsonrpc": .string("2.0"),
                    "id": .number(Double(id)),
                    "method": .string("_session/steering"),
                    "params": .object([
                        "sessionId": .string(sessionId),
                        "prompt": Self.textPrompt(prompt),
                        "_meta": .object(["steering": .object(["idleBehavior": .string("promptRequired")])])
                    ])
                ]))
            } catch {
                // A failed write can leave delivery ambiguous. Avoid replaying
                // a prompt that the agent may already have accepted.
                finishSteering(key: key, outcome: .unconfirmed)
            }
        }
    }

    func resolveSteering(key: String, body: [String: JSONValue]) {
        let outcome: SteeringOutcome
        switch (body["result"]?["outcome"]?.stringValue, body["error"]?["code"]?.intValue) {
        case ("injected", _):
            outcome = .injected
        case ("promptRequired", _), (_, -32600), (_, -32601), (_, -32602):
            outcome = .declined
        default:
            outcome = .unconfirmed
        }
        finishSteering(key: key, outcome: outcome)
        if body["error"]?["code"]?.intValue == -32601 {
            mutateSession(key) { $0.supportsHostOwnedSteering = false }
            sessions[key]?.continuation?.yield(.acpSteeringAvailable(false))
        }
    }

    func finishSteering(key: String, outcome: SteeringOutcome) {
        guard let request = sessions[key]?.steering else { return }
        mutateSession(key) { $0.steering = nil }
        request.timer.cancel()
        if outcome != .declined {
            sessions[key]?.continuation?.yield(.acpSteeredMessage(request.message, confirmed: outcome == .injected))
        }
        for update in request.updates { handleSessionUpdate(key: key, params: update) }
        request.reply.resume(returning: outcome)
        request.promptCompletion?.resume()
    }

    func waitForSteeringResponse(key: String) async {
        guard sessions[key]?.steering != nil else { return }
        await withCheckedContinuation { completion in
            mutateSession(key) { $0.steering?.promptCompletion = completion }
        }
    }

    static func textPrompt(_ prompt: String) -> JSONValue {
        .array([.object(["type": .string("text"), "text": .string(prompt)])])
    }
}
