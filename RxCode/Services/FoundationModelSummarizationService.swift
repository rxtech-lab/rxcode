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
        let trimmedDiff = String(diff.prefix(8000))
        let prompt = """
        Write a Git commit message for the staged changes below. Use the Conventional Commits style: a single subject line under 72 characters (type: summary), optionally followed by a blank line and a short body of 1-3 bullet points or sentences explaining the why. Reply with only the commit message — no quotes, no markdown fences.

        Staged files:
        \(fileSummary)

        Staged diff:
        \(trimmedDiff)
        """
        let raw = await respond(
            instructions: "You write clear, conventional Git commit messages.",
            prompt: prompt
        )
        return cleanSummary(raw, limit: 1000)
    }

    private func respond(instructions: String, prompt: String) async -> String? {
        guard Self.isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            logger.warning("Foundation Models summarization failed: \(error.localizedDescription)")
            return nil
        }
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
