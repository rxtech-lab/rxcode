import Foundation
import RxAgentCore
import RxAgentHarness
import RxCodeCore

// MARK: - Bridges RxCode IDE Tools into RxAgentHarness (`AgentProvider.localAgent`)

nonisolated struct IDEToolHarnessBridge: HarnessTool {
    let tool: IDETool
    let sessionKeyProvider: @Sendable () async -> String
    let callHandler: @Sendable (String, RxCodeCore.JSONValue, String) async throws -> RxCodeCore.JSONValue

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: RxAgentCore.JSONValue { SDKJSON(tool.inputSchema) }
    var isReadOnly: Bool {
        tool.name.contains("get_")
            || tool.name.contains("list_")
            || tool.name.contains("search_")
            || tool.name == "ide__briefing_list"
            || tool.name == "ide__briefing_get"
    }

    func execute(_ input: RxAgentCore.JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        let appArguments = AppJSON(input)
        let resolvedSessionKey = await sessionKeyProvider()
        let key = resolvedSessionKey.isEmpty ? context.sessionID : resolvedSessionKey
        do {
            let result = try await callHandler(tool.name, appArguments, key)
            return try Self.output(result, title: tool.name)
        } catch {
            return HarnessToolOutput(
                text: "IDE tool \(tool.name) failed: \(error.localizedDescription)",
                isError: true,
                title: "\(tool.name) error"
            )
        }
    }

    /// Preserve actual image blocks instead of sending base64 as model-readable text.
    static func output(_ result: RxCodeCore.JSONValue, title: String) throws -> HarnessToolOutput {
        if case .array(let blocks) = result["content"] {
            let isError = result["isError"]?.boolValue ?? false
            let images = (isError ? [] : blocks).compactMap { block -> HarnessImage? in
                guard block["type"]?.stringValue == "image",
                      let mime = block["mimeType"]?.stringValue,
                      let encoded = block["data"]?.stringValue,
                      let bytes = Data(base64Encoded: encoded) else { return nil }
                return HarnessImage(mimeType: mime, data: bytes)
            }
            let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            return HarnessToolOutput(text: text, isError: isError,
                                     title: title, images: images)
        }
        let data = try JSONEncoder().encode(result)
        return HarnessToolOutput(text: String(data: data, encoding: .utf8) ?? "{}", title: title)
    }

    static func makeAllTools(
        capabilities: CapabilitySet = RxCodeCore.AgentProvider.localAgent.staticCapabilities,
        sessionKeyProvider: @escaping @Sendable () async -> String,
        callHandler: @escaping @Sendable (String, RxCodeCore.JSONValue, String) async throws -> RxCodeCore.JSONValue
    ) -> [any HarnessTool] {
        IDEToolRegistry.tools(for: capabilities).map { ideTool in
            IDEToolHarnessBridge(
                tool: ideTool,
                sessionKeyProvider: sessionKeyProvider,
                callHandler: callHandler
            )
        }
    }
}
