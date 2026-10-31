import Foundation
import os
import MLX
import MLXLLM
import MLXLMCommon
import RxAgentCore
import RxAgentHarness
import Tokenizers

/// Native, offline inference. Downloading and authentication remain owned by LocalModelStore.
nonisolated enum NativeMLXInference {
  static func load(directory: URL) async throws -> ModelContainer {
    try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
  }

  static func generate(
    container: ModelContainer, request: HarnessModelRequest, contextSize: Int,
    promptCache: NativeMLXPromptCache,
    continuation: AsyncThrowingStream<HarnessModelChunk, Error>.Continuation
  ) async throws {
    guard request.messages.allSatisfy({ $0.images.isEmpty }) else {
      throw HarnessModelError.unavailable(
        "Native MLX currently supports text models only. Remove image attachments.")
    }
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "RxCode/local-tool-context")
    let request = try LocalModelContext.compact(request, directory: directory)
    let tools = toolSpecs(request)
    try await container.perform { context in
      try Task.checkCancellation()
      let input = try await context.processor.prepare(
        input: UserInput(messages: messages(request), tools: tools))
      let tokens = input.text.tokens.asArray(Int.self)
      let promptTokens = tokens.count
      try LocalModelContext.checkCompaction(request, promptTokens: promptTokens, contextSize: contextSize)
      let outputLimit = try outputBudget(
        promptTokens: promptTokens, contextSize: contextSize, requested: request.maxOutputTokens)
      let parameters = GenerateParameters(
        maxTokens: outputLimit, temperature: Float(request.temperature ?? 0.6))
      let reused = promptCache.prepare(tokens: tokens)
      if promptCache.layers.isEmpty {
        promptCache.layers = try context.model.newCache(parameters: parameters)
      }
      let suffix = LMInput(text: .init(tokens: MLXArray(Array(tokens.dropFirst(reused)))))
      let iterator = try TokenIterator(
        input: suffix, model: context.model, cache: promptCache.layers, parameters: parameters)
      let (stream, worker) = MLXLMCommon.generateTask(
        promptTokenCount: promptTokens - reused, modelConfiguration: context.configuration,
        tokenizer: context.tokenizer, iterator: iterator, tools: tools)
      do {
        try await withTaskCancellationHandler {
          var thinking = NativeMLXThinkingSplitter()
          var calledTool = false
          var finishReason = "stop"
          for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .chunk(let text):
              for chunk in thinking.feed(text) { continuation.yield(chunk) }
            case .toolCall(let call):
              calledTool = true
              let data = try JSONEncoder().encode(call.function.arguments)
              continuation.yield(
                .toolCall(
                  HarnessToolCall(
                    id: call.id ?? "call_\(UUID().uuidString)", name: call.function.name,
                    argumentsJSON: String(decoding: data, as: UTF8.self)
                  )))
            case .rejectedToolCall:
              throw HarnessModelError.malformed(
                "The MLX model generated an invalid or unauthorized tool call.")
            case .info(let info):
              Logger(subsystem: "com.rxlab.RxCode", category: "LocalPromptCache").info(
                "mlx prompt_tokens=\(promptTokens) cached_tokens=\(reused) output_tokens=\(info.generationTokenCount) prefill_seconds=\(info.promptTime) generation_seconds=\(info.generateTime)")
              continuation.yield(
                .usage(
                  UsageInfo(
                    inputTokens: promptTokens, outputTokens: info.generationTokenCount,
                    cacheReadTokens: reused, cacheCreationTokens: 0
                  )))
              switch info.stopReason {
              case .length: finishReason = "length"
              case .cancelled: throw CancellationError()
              case .stop: break
              }
            }
          }
          try Task.checkCancellation()
          for chunk in thinking.finish() { continuation.yield(chunk) }
          await worker.value
          try Task.checkCancellation()
          promptCache.retainPrompt(tokens)
          continuation.yield(.finished(reason: calledTool ? "tool_calls" : finishReason))
        } onCancel: {
          worker.cancel()
        }
      } catch {
        worker.cancel()
        await worker.value
        promptCache.clear()
        throw error
      }
    }
  }

  static func outputBudget(promptTokens: Int, contextSize: Int, requested: Int?) throws -> Int {
    guard promptTokens < contextSize else {
      throw HarnessModelError.contextOverflow(
        "The prompt contains \(promptTokens) tokens; the configured limit is \(contextSize).")
    }
    return min(max(1, requested ?? 4096), contextSize - promptTokens)
  }

  static func messages(_ request: HarnessModelRequest) -> [[String: any Sendable]] {
    var result: [[String: any Sendable]] = []
    if !request.system.isEmpty { result.append(["role": "system", "content": request.system]) }
    for message in request.messages {
      var item: [String: any Sendable] = ["role": message.role.rawValue, "content": message.text]
      if message.role == .tool {
        item["tool_call_id"] = message.toolCallID ?? ""
        item["name"] = message.toolName ?? ""
      }
      if let reasoning = message.reasoning { item["reasoning_content"] = reasoning }
      if !message.toolCalls.isEmpty {
        item["tool_calls"] = message.toolCalls.map { call -> [String: any Sendable] in
          [
            "id": call.id, "type": "function",
            "function": [
              "name": call.name, "arguments": value(call.arguments ?? .object([:])),
            ] as [String: any Sendable],
          ]
        }
      }
      result.append(item)
    }
    return result
  }

  static func toolSpecs(_ request: HarnessModelRequest) -> [[String: any Sendable]] {
    request.tools.map { tool in
      [
        "type": "function",
        "function": [
          "name": tool.name, "description": tool.description, "parameters": value(tool.parameters),
        ] as [String: any Sendable],
      ]
    }
  }

  private static func value(_ json: RxAgentCore.JSONValue) -> any Sendable {
    switch json {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    case .null: Optional<String>.none
    case .array(let values): values.map(value)
    case .object(let values): values.mapValues(value)
    }
  }
}

/// Accessed only by the manager's single active native generation, inside
/// ModelContainer.perform. Unload replaces the whole object, so a cancelled
/// generation cannot repopulate the next model's cache.
nonisolated final class NativeMLXPromptCache: @unchecked Sendable {
  var layers: [any KVCache] = []
  private var tokens: [Int] = []

  static func reusablePrefix(cached: [Int], incoming: [Int]) -> Int {
    // Leave one token to evaluate, even for an identical or shorter prompt.
    min(zip(cached, incoming).prefix { $0 == $1 }.count, max(0, incoming.count - 1))
  }

  func prepare(tokens incoming: [Int]) -> Int {
    let count = Self.reusablePrefix(cached: tokens, incoming: incoming)
    guard count > 0, rewind(to: count) else {
      clear()
      return 0
    }
    tokens = Array(tokens.prefix(count))
    return count
  }

  func retainPrompt(_ prompt: [Int]) {
    // Generated tokens are not reconstructed from decoded text: tokenization
    // can differ. Keep only the exact input tokens represented by the cache.
    guard rewind(to: prompt.count) else {
      clear()
      return
    }
    tokens = prompt
  }

  private func rewind(to count: Int) -> Bool {
    guard !layers.isEmpty, layers.allSatisfy({ $0.isTrimmable && $0.offset >= count }) else {
      return false
    }
    for layer in layers {
      let removed = layer.offset - count
      guard layer.trim(removed) == removed, layer.offset == count else { return false }
    }
    return true
  }

  func clear() {
    layers = []
    tokens = []
  }
}

nonisolated struct NativeMLXHarnessModel: HarnessModel {
  let manager: LlamaServerManager
  let model: LocalModelInfo
  let modelsRoot: URL
  let contextWindow: Int?

  func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await manager.generateNative(
            model: model, modelsRoot: modelsRoot,
            context: contextWindow ?? 8192, request: request, continuation: continuation)
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

nonisolated private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    LocalTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
  }
}

nonisolated private struct LocalTokenizer: MLXLMCommon.Tokenizer {
  let upstream: any Tokenizers.Tokenizer
  func encode(text: String, addSpecialTokens: Bool) -> [Int] {
    upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
  }
  func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
    upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
  }
  func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
  func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
  var bosToken: String? { upstream.bosToken }
  var eosToken: String? { upstream.eosToken }
  var unknownToken: String? { upstream.unknownToken }
  func applyChatTemplate(
    messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
    additionalContext: [String: any Sendable]?
  ) throws -> [Int] {
    do {
      return try upstream.applyChatTemplate(
        messages: messages, tools: tools, additionalContext: additionalContext)
    } catch Tokenizers.TokenizerError.missingChatTemplate {
      throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
  }
}

/// Handles reasoning delimiters even when a token chunk splits the delimiter.
nonisolated struct NativeMLXThinkingSplitter {
  private var buffer = ""
  private var thinking = false
  mutating func feed(_ text: String) -> [HarnessModelChunk] {
    buffer += text
    var chunks: [HarnessModelChunk] = []
    while true {
      let tag = thinking ? "</think>" : "<think>"
      if let range = buffer.range(of: tag) {
        let prefix = String(buffer[..<range.lowerBound])
        if !prefix.isEmpty {
          chunks.append(thinking ? .reasoningDelta(prefix) : .textDelta(prefix))
        }
        buffer = String(buffer[range.upperBound...])
        thinking.toggle()
        continue
      }
      let keep =
        (1..<tag.count).reversed().first {
          buffer.count >= $0 && tag.hasPrefix(String(buffer.suffix($0)))
        } ?? 0
      let text = String(buffer.dropLast(keep))
      buffer = String(buffer.suffix(keep))
      if !text.isEmpty { chunks.append(thinking ? .reasoningDelta(text) : .textDelta(text)) }
      return chunks
    }
  }
  mutating func finish() -> [HarnessModelChunk] {
    defer { buffer = "" }
    return buffer.isEmpty ? [] : [thinking ? .reasoningDelta(buffer) : .textDelta(buffer)]
  }
}
