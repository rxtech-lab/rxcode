import Foundation
import RxCodeCore
import os

// MARK: - Title & Summary Generation

extension ClaudeCodeServer {

    /// Generate a short 3–6 word title for a chat from the first user message.
    /// Uses a one-shot `claude -p` invocation with Haiku — runs outside of the streaming
    /// pipeline and does NOT hit the PermissionServer hook (no `--settings` passed).
    /// Returns nil on any failure; callers should keep the placeholder title in that case.
    func generateSessionTitle(firstUserMessage: String, model: String = "claude-haiku-4-5-20251001") async -> String? {
        guard let binary = await findClaudeBinary() else { return nil }
        let trimmedUser = String(firstUserMessage.prefix(500))
        let prompt = """
        Summarize the following user message as a 3-6 word chat title. \
        Reply with ONLY the title, no quotes, no markdown, no punctuation at the end.

        \(trimmedUser)
        """
        // Title generation is pure text — no tools needed. Strip MCP servers so a
        // user's broken tool schema (e.g. an MCP server returning invalid JSON schema)
        // can't blow up the title call with "API Error: 400 tools.NN.custom.input_schema".
        let emptyMCPConfigPath = writeEmptyMCPConfig()
        var args: [String] = ["-p", prompt, "--output-format", "text", "--model", model]
        if let emptyMCPConfigPath {
            args.append(contentsOf: ["--strict-mcp-config", "--mcp-config", emptyMCPConfigPath])
        }
        do {
            let output = try await runShellCommand(binary, arguments: args)
            let cleaned = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !cleaned.isEmpty else { return nil }
            // `claude -p` prints API/CLI failures to stdout (e.g. "API Error: 400 ...").
            // Don't promote those to the sidebar title — keep the placeholder instead.
            let lower = cleaned.lowercased()
            let errorPrefixes = ["api error", "error:", "execution error", "request failed", "claude error"]
            if errorPrefixes.contains(where: { lower.hasPrefix($0) }) {
                logger.warning("Title generation produced an error string; ignoring: \(cleaned.prefix(120))")
                return nil
            }
            return String(cleaned.prefix(80))
        } catch {
            logger.warning("Title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func generateResponseNotificationSummary(responseText: String, model: String = "claude-haiku-4-5-20251001") async -> String? {
        guard let binary = await findClaudeBinary() else { return nil }
        let trimmedResponse = String(responseText.prefix(4000))
        let prompt = """
        Summarize the following assistant response for a macOS notification. \
        Reply with one concise sentence under 180 characters. Mention the outcome and the most important result. \
        No markdown.

        \(trimmedResponse)
        """
        let emptyMCPConfigPath = writeEmptyMCPConfig()
        var args: [String] = ["-p", prompt, "--output-format", "text", "--model", model]
        if let emptyMCPConfigPath {
            args.append(contentsOf: ["--strict-mcp-config", "--mcp-config", emptyMCPConfigPath])
        }
        do {
            let output = try await runShellCommand(binary, arguments: args)
            let cleaned = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            guard !cleaned.isEmpty else { return nil }
            let lower = cleaned.lowercased()
            let errorPrefixes = ["api error", "error:", "execution error", "request failed", "claude error"]
            if errorPrefixes.contains(where: { lower.hasPrefix($0) }) {
                logger.warning("Notification summary produced an error string; ignoring: \(cleaned.prefix(120))")
                return nil
            }
            return String(cleaned.prefix(180))
        } catch {
            logger.warning("Notification summary generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func generateThreadSummary(
        previousSummary: String?,
        userMessage: String,
        finalResponse: String,
        model: String = "claude-haiku-4-5-20251001"
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
        return await generatePlainSummary(prompt: prompt, model: model, limit: 1800)
    }

    func generateMemoryOperations(
        existingMemories: [(id: String, content: String)],
        userMessages: [String],
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: existingMemories,
            userMessages: userMessages
        )
        return await generatePlainSummary(prompt: prompt, model: model, limit: 3000)
    }

    func generateBranchBriefing(
        threadSummaries: [(title: String, summary: String)],
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        guard !threadSummaries.isEmpty else { return nil }
        let prompt = OpenAISummarizationService.branchBriefingPrompt(threadSummaries: threadSummaries)
        return await generatePlainSummary(prompt: prompt, model: model, limit: 1800)
    }

    func generateCommitMessage(
        diff: String,
        fileSummary: String,
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        // Caller (AppState) has already applied a provider-aware budget; this
        // is just an upper bound to guard against accidental misuse.
        let trimmedDiff = String(diff.prefix(20_000))
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
        return await generatePlainSummary(prompt: prompt, model: model, limit: 1000)
    }

    func generatePullRequestContent(
        briefing: String,
        branch: String,
        model: String = "claude-haiku-4-5-20251001"
    ) async -> String? {
        let prompt = OpenAISummarizationService.pullRequestPrompt(briefing: briefing, branch: branch)
        return await generatePlainSummary(prompt: prompt, model: model, limit: 4000)
    }

    /// Generate a Swift "show condition" for a custom menu item from a natural
    /// language requirement. Returns *only* the `checkShowMenu(context:)` function
    /// body (markdown fences stripped) — the caller compiles it before accepting.
    /// Unlike `generatePlainSummary`, the output is preserved verbatim (no summary
    /// sanitizer) so code formatting/newlines survive.
    func generateConditionScript(requirement: String, model: String) async -> String? {
        guard let binary = await findClaudeBinary() else { return nil }
        let emptyMCPConfigPath = writeEmptyMCPConfig()
        let prompt = """
        You are writing a Swift "show condition" for a custom context-menu item in a macOS app.
        Output ONLY a single Swift function — no prose, no markdown, no extra declarations:

            func checkShowMenu(context: Context) async throws -> Bool { ... }

        Return true to SHOW the menu item, false to HIDE it.

        The `Context` type is already defined elsewhere — do NOT redeclare it. Its API:
            struct Context {
                let projectName: String
                let projectPath: String
                let gitHubRepo: String   // "owner/repo", or empty
                let branch: String       // current branch, or empty
                let sessionId: String    // thread id, or empty
                // runs in the project directory, returns trimmed combined output:
                func shell(_ command: String) async throws -> String
                func git(_ args: String...) async throws -> String
            }

        Foundation is available. Keep the check read-only (no mutations). Use `try await`
        for context.shell/context.git. Return only the function.

        Requirement: \(requirement)
        """
        var args: [String] = ["-p", prompt, "--output-format", "text", "--model", model]
        if let emptyMCPConfigPath {
            args.append(contentsOf: ["--strict-mcp-config", "--mcp-config", emptyMCPConfigPath])
        }
        do {
            let output = try await runShellCommand(binary, arguments: args)
            return Self.extractGeneratedSwift(from: output)
        } catch {
            logger.warning("Condition script generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Pull the Swift source out of a model reply, stripping a single ```/```swift
    /// fenced block if present. Returns nil for empty output.
    static func extractGeneratedSwift(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let fenceStart = text.range(of: "```") {
            var rest = String(text[fenceStart.upperBound...])
            // Drop an optional language tag (e.g. "swift") on the opening fence line.
            if let newline = rest.firstIndex(of: "\n") {
                let firstLine = rest[..<newline].trimmingCharacters(in: .whitespaces)
                if firstLine.isEmpty || firstLine.lowercased() == "swift" {
                    rest = String(rest[rest.index(after: newline)...])
                }
            }
            if let fenceEnd = rest.range(of: "```") {
                rest = String(rest[..<fenceEnd.lowerBound])
            }
            text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    func generatePlainSummary(prompt: String, model: String, limit: Int) async -> String? {
        guard let binary = await findClaudeBinary() else { return nil }
        let emptyMCPConfigPath = writeEmptyMCPConfig()
        var args: [String] = ["-p", prompt, "--output-format", "text", "--model", model]
        if let emptyMCPConfigPath {
            args.append(contentsOf: ["--strict-mcp-config", "--mcp-config", emptyMCPConfigPath])
        }
        do {
            let output = try await runShellCommand(binary, arguments: args)
            return cleanGeneratedSummary(output, limit: limit)
        } catch {
            logger.warning("Summary generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func cleanGeneratedSummary(_ raw: String, limit: Int) -> String? {
        let errorPrefixes = ["api error", "error:", "execution error", "request failed", "claude error"]
        return GeneratedTextSanitizer.cleanSummary(raw, limit: limit, errorPrefixes: errorPrefixes)
    }

    /// Write a one-off MCP config file (with no servers) used by the title-generation
    /// call so it doesn't inherit user-level MCP servers. Returns nil on I/O failure;
    /// caller falls back to the default config.
    func writeEmptyMCPConfig() -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RxCode", isDirectory: true)
        let path = dir.appendingPathComponent("empty-mcp.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"mcpServers\":{}}".utf8).write(to: path, options: .atomic)
            return path.path
        } catch {
            logger.warning("Failed to write empty MCP config: \(error.localizedDescription)")
            return nil
        }
    }
}
