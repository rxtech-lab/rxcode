import Foundation
import FoundationModels
import os

/// On-device summarization powered by Apple's Foundation Models framework
/// (Apple Intelligence). Free, private, and runs locally — but only available
/// on Apple Silicon Macs with Apple Intelligence enabled.
actor FoundationModelSummarizationService {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "FoundationModelSummarizationService"
    )

    /// Whether the on-device model is currently usable. Re-evaluated on each
    /// call so toggling Apple Intelligence in System Settings is picked up
    /// without a relaunch.
    nonisolated static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Human-readable reason the model is unavailable, or `nil` if available.
    nonisolated static var unavailabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence isn't enabled. Turn it on in System Settings."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again later."
        case .unavailable:
            return "Apple Intelligence is unavailable on this device."
        }
    }

    func generateSessionTitle(firstUserMessage: String) async -> String? {
        let trimmed = String(firstUserMessage.prefix(500))
        let prompt = """
        Summarize the following user message as a 3-6 word chat title. Reply with ONLY the title, no quotes, no markdown, no punctuation at the end.

        \(trimmed)
        """
        let raw = await respond(
            instructions: "You generate concise chat titles.",
            prompt: prompt
        )
        return cleanTitle(raw)
    }

    func generateResponseNotificationSummary(responseText: String) async -> String? {
        let trimmed = String(responseText.prefix(4000))
        let prompt = """
        Summarize the following assistant response for a macOS notification. Reply with one concise sentence under 180 characters. Mention the outcome and the most important result. No markdown.

        \(trimmed)
        """
        let raw = await respond(
            instructions: "You write concise notification summaries.",
            prompt: prompt
        )
        return cleanSummary(raw, limit: 180)
    }

    func generateThreadSummary(
        previousSummary: String?,
        userMessage: String,
        finalResponse: String
    ) async -> String? {
        let previous = previousSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Update the stored summary for one project thread. Use the previous summary, latest user request, and final assistant response.
        Keep it factual and concise, 3-6 bullet points max. Include completed work, important decisions, files or areas touched, and unresolved follow-ups.
        Reply with only the updated summary.

        Previous summary:
        \((previous?.isEmpty == false) ? previous! : "None")

        Latest user request:
        \(String(userMessage.prefix(2000)))

        Final assistant response:
        \(String(finalResponse.prefix(4000)))
        """
        let raw = await respond(
            instructions: "You maintain concise local project summaries.",
            prompt: prompt
        )
        return cleanSummary(raw, limit: 1800)
    }

    func generateMemoryOperations(
        existingMemories: [(id: String, content: String)],
        userMessages: [String]
    ) async -> String? {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: existingMemories,
            userMessages: userMessages
        )
        let raw = await respond(
            instructions: "You extract concise durable memory as JSON operations. Output only JSON.",
            prompt: prompt
        )
        return cleanSummary(raw, limit: 3000)
    }

    func generateBranchBriefing(
        threadSummaries: [(title: String, summary: String)]
    ) async -> String? {
        guard !threadSummaries.isEmpty else { return nil }
        let joined = threadSummaries.map { item -> String in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = String(item.summary.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "### \(title.isEmpty ? "Untitled thread" : title)\n\(summary)"
        }.joined(separator: "\n\n")

        let prompt = """
        Write a concise overall briefing for one git branch by synthesizing the per-thread summaries below into a single coherent overview.
        Cover the main themes, completed work, important decisions, files or areas touched, and unresolved follow-ups across the whole branch.
        Do not list threads individually — produce a unified summary. Use 4-8 short bullet points. Reply with only the briefing.

        Thread summaries (newest first):

        \(joined)
        """
        let raw = await respond(
            instructions: "You maintain concise local project summaries.",
            prompt: prompt
        )
        return cleanSummary(raw, limit: 1800)
    }

    func generateCommitMessage(diff: String, fileSummary: String) async -> String? {
        // Caller (AppState) has already applied a much tighter budget for the
        // on-device model. This prefix is a hard safety cap.
        let trimmedDiff = String(diff.prefix(4_000))
        let prompt = """
        Write a Git commit message for the staged changes below in the Conventional Commits format.

        Format rules (MUST follow exactly):
        - First line: `<type>(<optional-scope>): <description>` — subject must be under 72 characters, lowercase imperative mood, no trailing period.
        - `<type>` MUST be one of: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert.
        - After the subject, an optional blank line followed by 1-3 short bullet points explaining the WHY (each starting with "- ").
        - Do NOT use markdown headings (no `#`, `##`).
        - Do NOT wrap the message in quotes or code fences.
        - Do NOT prefix with anything else; the very first characters must be the type.

        Example output:
        feat(git): add commit message generator

        - reuse summarization providers for on-device generation
        - support staged diff context

        Staged files:
        \(fileSummary)

        Staged diff:
        \(trimmedDiff)
        """
        let raw = await respond(
            instructions: "You write Conventional Commits commit messages. Output only the message, never explanations or markdown headings.",
            prompt: prompt
        )
        return cleanSummary(raw, limit: 1000)
    }

    private func respond(instructions: String, prompt: String) async -> String? {
        guard Self.isAvailable else { return nil }
        return await respond(instructions: instructions, prompt: prompt, allowRollingWindow: true)
    }

    private func respond(
        instructions: String,
        prompt: String,
        allowRollingWindow: Bool
    ) async -> String? {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            if allowRollingWindow, Self.isContextWindowError(error) {
                logger.notice("Foundation Models context window exceeded; retrying with rolling-window compression (\(prompt.count) chars)")
                return await respondWithRollingWindow(instructions: instructions, prompt: prompt)
            }
            logger.warning("Foundation Models summarization failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-runs the original (instructions, prompt) pair after compressing the
    /// prompt with a rolling-window pass that builds up an accumulated summary
    /// chunk-by-chunk. Each pass halves the chunk size so we converge even when
    /// the model's window is very small.
    private func respondWithRollingWindow(
        instructions: String,
        prompt: String
    ) async -> String? {
        let attempts = [2_500, 1_200, 600]
        var workingPrompt = prompt
        for chunkChars in attempts {
            guard let compressed = await rollingWindowCompress(
                text: workingPrompt,
                chunkChars: chunkChars
            ), !compressed.isEmpty else {
                return nil
            }
            workingPrompt = compressed
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: workingPrompt)
                return response.content
            } catch {
                if Self.isContextWindowError(error) {
                    continue
                }
                logger.warning("Foundation Models rolling-window retry failed: \(error.localizedDescription)")
                return nil
            }
        }
        logger.warning("Foundation Models rolling-window gave up after \(attempts.count) attempts")
        return nil
    }

    /// Splits `text` into chunks and folds them into a single accumulated
    /// summary: `summary = compress(summary + nextChunk)`. Returns the final
    /// accumulated summary (already shorter than the original).
    private func rollingWindowCompress(
        text: String,
        chunkChars: Int
    ) async -> String? {
        let chunks = Self.splitIntoChunks(text: text, chunkChars: chunkChars)
        guard !chunks.isEmpty else { return nil }
        var accumulated = ""
        for chunk in chunks {
            let merged: String
            if accumulated.isEmpty {
                merged = chunk
            } else {
                merged = """
                Summary so far:
                \(accumulated)

                Additional content to incorporate (preserve key facts, decisions, file paths, identifiers, and intent):
                \(chunk)
                """
            }
            do {
                let session = LanguageModelSession(
                    instructions: "You compress long text into a concise running summary while preserving key facts, decisions, file paths, identifiers, and intent. Output only the compressed text, no preamble."
                )
                let response = try await session.respond(to: merged)
                accumulated = response.content
            } catch {
                if Self.isContextWindowError(error), chunkChars > 400 {
                    guard let inner = await rollingWindowCompress(
                        text: chunk,
                        chunkChars: max(400, chunkChars / 2)
                    ) else {
                        return nil
                    }
                    accumulated = accumulated.isEmpty ? inner : "\(accumulated)\n\n\(inner)"
                } else {
                    logger.warning("Foundation Models rolling-window compression failed: \(error.localizedDescription)")
                    return nil
                }
            }
        }
        return accumulated
    }

    private static func isContextWindowError(_ error: Error) -> Bool {
        if let generationError = error as? LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = generationError {
                return true
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("context window")
    }

    private static func splitIntoChunks(text: String, chunkChars: Int) -> [String] {
        guard text.count > chunkChars else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var current = ""
        let paragraphs = text.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            if paragraph.count > chunkChars {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                var idx = paragraph.startIndex
                while idx < paragraph.endIndex {
                    let end = paragraph.index(idx, offsetBy: chunkChars, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                    chunks.append(String(paragraph[idx..<end]))
                    idx = end
                }
                continue
            }
            if current.count + paragraph.count + 2 > chunkChars {
                if !current.isEmpty {
                    chunks.append(current)
                }
                current = paragraph
            } else {
                current = current.isEmpty ? paragraph : "\(current)\n\n\(paragraph)"
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(80))
    }

    private func cleanSummary(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(limit))
    }
}
