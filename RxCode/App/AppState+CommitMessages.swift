import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    /// Drafts with the selected model in the checkout being committed. A nil
    /// selection uses the workspace's summarization settings.
    func generateCommitMessage(
        diff: String, stat: String, fileSummary: String, model: AgentModel?, cwd: String
    ) async throws -> String? {
        guard let model else {
            return await generateCommitMessage(diff: diff, stat: stat, fileSummary: fileSummary)
        }

        let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 16_000)
        let prompt = OpenAISummarizationService.commitMessagePrompt(diff: context, fileSummary: fileSummary)
        let raw: String?
        switch model.provider {
        case .claudeCode:
            raw = await claude.generatePlainSummary(prompt: prompt, model: model.id, limit: 1000)
        case .codex:
            raw = await codex.generateCodexPlainSummary(prompt: prompt, model: model.id)
        case .acp:
            guard let selection = acpSelectionParts(for: model.id),
                  let client = acpClients.first(where: { $0.id == selection.clientId && $0.enabled })
            else { return nil }
            raw = await acp.generatePlainResponse(
                prompt: prompt, model: selection.model.isEmpty ? nil : selection.model, spec: client, cwd: cwd
            )
        case .flowcy:
            raw = try await flowcyCloudBackend.reply(model: model.id, prompt: prompt)
        case .localAgent:
            raw = try await LocalAgentBackendFactory.generateTextCompletion(prompt: prompt, modelID: model.id, store: localModels)
        }
        return Self.sanitizeCommitMessage(raw)
    }

    /// Generates a commit message for the staged changes in the given project.
    /// Routes through the configured `summarizationProvider`. Returns nil on
    /// failure or when no provider is configured. Public so the Changes view
    /// can invoke it from the UI thread.
    ///
    /// `diff` and `stat` should come from `GitHelper.stagedDiff` /
    /// `GitHelper.stagedStat`. We compact them per-provider so very large
    /// patches don't blow past the model's context window — the small
    /// on-device Foundation Model gets a much tighter budget than the
    /// cloud-hosted providers.
    func generateCommitMessage(
        diff: String,
        stat: String,
        fileSummary: String
    ) async -> String? {
        let raw: String?
        switch summarizationProvider {
        case .appleFoundationModel:
            let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 2_500)
            raw = await foundationModelSummarization.generateCommitMessage(
                diff: context,
                fileSummary: fileSummary
            )
        case .openAI:
            if openAISummarizationModel.isEmpty {
                if FoundationModelSummarizationService.isAvailable {
                    let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 2_500)
                    raw = await foundationModelSummarization.generateCommitMessage(
                        diff: context,
                        fileSummary: fileSummary
                    )
                } else {
                    raw = nil
                }
            } else {
                let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 16_000)
                raw = await openAISummarization.generateCommitMessage(
                    diff: context,
                    fileSummary: fileSummary,
                    endpoint: openAISummarizationEndpoint,
                    apiKey: openAISummarizationAPIKey,
                    model: openAISummarizationModel
                )
            }
        case .selectedClient:
            if FoundationModelSummarizationService.isAvailable {
                let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 2_500)
                raw = await foundationModelSummarization.generateCommitMessage(
                    diff: context,
                    fileSummary: fileSummary
                )
            } else {
                let context = Self.buildCommitContext(diff: diff, stat: stat, budget: 16_000)
                raw = await claude.generateCommitMessage(diff: context, fileSummary: fileSummary)
            }
        }
        return Self.sanitizeCommitMessage(raw)
    }

    /// Builds a compact diff context that fits within `budget` characters.
    /// When the raw diff fits, returns it as-is (prefixed with the stat).
    /// When it doesn't, splits by `diff --git` boundaries and gives each file
    /// a fair share of the remaining budget — keeping the header plus the
    /// leading lines of the patch so the model still sees what changed in
    /// each file, even if deeper context is dropped.
    static func buildCommitContext(diff: String, stat: String, budget: Int) -> String {
        let statBlock: String = {
            let trimmed = stat.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : "Diff stat:\n\(trimmed)\n\n"
        }()

        let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDiff.isEmpty {
            return statBlock + "Full diff:\n(none)"
        }

        // Fast path — total fits within budget.
        if statBlock.count + trimmedDiff.count <= budget {
            return statBlock + "Full diff:\n" + trimmedDiff
        }

        // Split by file boundaries. The first chunk before any "diff --git" is
        // ignored (git always starts file blocks with that marker).
        let marker = "\ndiff --git "
        var fileBlocks: [String] = []
        var remaining = "\n" + trimmedDiff
        while let range = remaining.range(of: marker) {
            let nextStart = remaining.index(range.lowerBound, offsetBy: 1) // drop leading "\n"
            if let next = remaining.range(of: marker, range: range.upperBound..<remaining.endIndex) {
                fileBlocks.append(String(remaining[nextStart..<next.lowerBound]))
                remaining = String(remaining[next.lowerBound..<remaining.endIndex])
            } else {
                fileBlocks.append(String(remaining[nextStart..<remaining.endIndex]))
                remaining = ""
            }
        }
        if fileBlocks.isEmpty {
            // No "diff --git" markers found — fall back to a head clip.
            let clipped = String(trimmedDiff.prefix(max(0, budget - statBlock.count - 64)))
            return statBlock + "Full diff (truncated):\n" + clipped + "\n…[truncated]"
        }

        let budgetForDiffs = max(0, budget - statBlock.count - 64)
        let perFile = max(300, budgetForDiffs / fileBlocks.count)
        var assembled = ""
        for block in fileBlocks {
            if block.count <= perFile {
                assembled += block
            } else {
                let head = String(block.prefix(perFile))
                assembled += head + "\n…[file diff truncated]\n"
            }
            if assembled.count >= budgetForDiffs { break }
        }

        return statBlock + "Truncated diff (file-by-file):\n" + assembled
    }

    /// Strips markdown wrappers and ensures the message starts with a
    /// Conventional Commits `type:` line. Defends against models that add
    /// headings, code fences, or quoted text despite explicit prompts.
    static func sanitizeCommitMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        // Strip fenced code blocks: ```...``` (any language tag).
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last?.trimmingCharacters(in: .whitespaces), last == "```" {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip surrounding quotes/backticks if the whole message is wrapped.
        if let first = text.first, let last = text.last,
           "\"'`".contains(first), first == last, text.count > 1 {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop leading lines that look like markdown headings or empty lines
        // until we reach a Conventional Commits subject (or any plain text).
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmed.hasPrefix("#")
            let isEmpty = trimmed.isEmpty
            let startsWithType = Self.conventionalCommitTypes.contains { type in
                trimmed.lowercased().hasPrefix(type + ":") ||
                trimmed.lowercased().hasPrefix(type + "(")
            }
            if startsWithType { break }
            if isHeading || isEmpty {
                lines.removeFirst()
                continue
            }
            break
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
