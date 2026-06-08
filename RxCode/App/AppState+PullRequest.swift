import Foundation
import os
import RxCodeCore

/// Errors surfaced while opening a pull request from a briefing card.
enum PullRequestError: LocalizedError {
    case noGitHubRepo
    case pushFailed(String)
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .noGitHubRepo:
            return "This project isn't linked to a GitHub repository."
        case .pushFailed(let message):
            return "Couldn't push the branch to GitHub.\n\n\(message)"
        case .createFailed(let message):
            return "Couldn't create the pull request.\n\n\(message)"
        }
    }
}

extension AppState {

    // MARK: - Create PR

    /// Open a pull request for `branch` of `project`: push the branch, generate a
    /// Conventional-Commit title + markdown body from the branch briefing, and
    /// ask autopilot to open the PR (base = repo default branch, resolved
    /// server-side). Refreshes CI/PR status on success and returns the PR URL.
    func createPullRequestForBranch(project: Project, branch: String) async throws -> URL {
        guard let slug = project.gitHubRepo else { throw PullRequestError.noGitHubRepo }
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw PullRequestError.noGitHubRepo
        }
        let owner = parts[0]
        let repo = parts[1]

        // 1. Publish the branch. `-u origin <branch>` is idempotent: it pushes any
        //    new commits and sets the upstream, and is a no-op when up to date.
        if let pushError = await GitHelper.push(
            at: project.path,
            remote: "origin",
            branch: branch,
            setUpstream: true
        ) {
            throw PullRequestError.pushFailed(pushError)
        }

        // 2. Generate the title + body from the branch briefing.
        let briefing = threadStore.allBranchBriefingItems()
            .first(where: { $0.projectId == project.id && $0.branch == branch })?
            .briefing ?? ""
        let (title, body) = await generateValidatedPullRequestContent(briefing: briefing, branch: branch)

        // 3. Open the PR via autopilot.
        let response: CreatePullRequestResponse
        do {
            response = try await autopilot.createPullRequest(
                CreatePullRequestRequest(
                    owner: owner,
                    repo: repo,
                    head: branch,
                    base: nil,
                    title: title,
                    body: body.isEmpty ? nil : body
                )
            )
        } catch {
            throw PullRequestError.createFailed(error.localizedDescription)
        }

        // 4. Refresh so the card flips from "Create PR" to the PR chip.
        await refreshCIStatusOnce()

        guard let url = URL(string: response.prUrl) else {
            throw PullRequestError.createFailed("The server returned an invalid PR URL.")
        }
        return url
    }

    /// Convenience for the project context menu, which has no branch in hand:
    /// resolve the project's current branch (the same way the CI poller does)
    /// and open a PR for it via ``createPullRequestForBranch(project:branch:)``.
    func createPullRequestForCurrentBranch(project: Project) async throws -> URL {
        guard let branch = await GitHelper.currentBranch(at: project.path), !branch.isEmpty else {
            throw PullRequestError.createFailed("Couldn't determine the current branch for this project.")
        }
        return try await createPullRequestForBranch(project: project, branch: branch)
    }

    // MARK: - Title / body generation

    /// Generate raw PR text (title on the first line, blank line, then a markdown
    /// body) from a branch briefing. Routes through the configured
    /// `summarizationProvider`, mirroring `generateCommitMessage`.
    func generatePullRequestContent(briefing: String, branch: String) async -> String? {
        switch summarizationProvider {
        case .appleFoundationModel:
            return await foundationModelSummarization.generatePullRequestContent(
                briefing: briefing,
                branch: branch
            )
        case .openAI:
            if openAISummarizationModel.isEmpty {
                if FoundationModelSummarizationService.isAvailable {
                    return await foundationModelSummarization.generatePullRequestContent(
                        briefing: briefing,
                        branch: branch
                    )
                }
                return nil
            }
            return await openAISummarization.generatePullRequestContent(
                briefing: briefing,
                branch: branch,
                endpoint: openAISummarizationEndpoint,
                apiKey: openAISummarizationAPIKey,
                model: openAISummarizationModel
            )
        case .selectedClient:
            if FoundationModelSummarizationService.isAvailable {
                return await foundationModelSummarization.generatePullRequestContent(
                    briefing: briefing,
                    branch: branch
                )
            }
            return await claude.generatePullRequestContent(briefing: briefing, branch: branch)
        }
    }

    /// Generate PR content and guarantee the title is a valid Conventional
    /// Commit (its `<type>` is one of ``conventionalCommitTypes``). The model
    /// occasionally returns a non-conforming title (e.g. `feature:` or a plain
    /// sentence); when it does we re-prompt up to `maxAttempts` times before
    /// falling back to a safe `chore:` title while keeping the generated body.
    func generateValidatedPullRequestContent(
        briefing: String,
        branch: String,
        maxAttempts: Int = 3
    ) async -> (title: String, body: String) {
        var lastBody = ""
        for attempt in 1...maxAttempts {
            let raw = await generatePullRequestContent(briefing: briefing, branch: branch)
            let (title, body) = Self.parsePullRequestContent(raw, branch: branch)
            if Self.isConventionalCommitTitle(title) {
                return (title, body)
            }
            lastBody = body
            logger.warning("PR title is not a valid Conventional Commit (attempt \(attempt)/\(maxAttempts)); retrying: \(title, privacy: .public)")
        }
        logger.warning("PR title still invalid after \(maxAttempts) attempts; using fallback title")
        return ("chore: update \(branch)", lastBody)
    }

    /// Conventional Commit `<type>` tokens accepted in commit and PR titles.
    /// Single source of truth shared across title generation, normalization, and
    /// validation.
    static let conventionalCommitTypes: Set<String> = [
        "feat", "fix", "docs", "style", "refactor", "perf",
        "test", "build", "ci", "chore", "revert"
    ]

    /// Maximum number of whitespace-separated words allowed in a generated PR
    /// title (including the Conventional-Commit `<type>:` prefix). Keeps titles
    /// short and scannable even when the model ignores the prompt's length hint.
    static let maxPullRequestTitleWords = 20

    /// Truncate `title` to at most ``maxPullRequestTitleWords`` whitespace-
    /// separated words. Returns the title unchanged when already within the
    /// limit; otherwise keeps the leading words and strips any trailing
    /// punctuation left dangling by the cut.
    static func truncatePullRequestTitleWords(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0.isWhitespace })
        guard words.count > maxPullRequestTitleWords else { return title }
        let kept = words.prefix(maxPullRequestTitleWords).joined(separator: " ")
        return stripTrailingPullRequestTitlePunctuation(kept)
    }

    /// True when `title` matches `<type>(<optional-scope>)<!>: <description>` and
    /// `<type>` is one of ``conventionalCommitTypes``. Used to gate generated PR
    /// titles so a non-conforming title triggers a model retry.
    static func isConventionalCommitTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pattern = #"^([A-Za-z]+)(\([^)\n]+\))?!?\s*:\s+\S.*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
              ),
              let typeRange = Range(match.range(at: 1), in: trimmed) else {
            return false
        }
        return conventionalCommitTypes.contains(trimmed[typeRange].lowercased())
    }

    /// Split generated PR text into a Conventional-Commit title and a markdown
    /// body. Tolerant of code fences, heading markers, surrounding quotes, and a
    /// stray `Title:` prefix. Falls back to a safe title when generation failed.
    static func parsePullRequestContent(_ raw: String?, branch: String) -> (title: String, body: String) {
        let fallbackTitle = "chore: update \(branch)"
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return (fallbackTitle, "")
        }

        // Unwrap a fenced block if the model wrapped the whole output.
        if text.hasPrefix("```") {
            var fenced = text.components(separatedBy: "\n")
            fenced.removeFirst()
            if let last = fenced.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.removeLast()
            }
            text = fenced.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = text.components(separatedBy: "\n")
        guard let firstIdx = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return (fallbackTitle, "")
        }

        var title = lines[firstIdx].trimmingCharacters(in: .whitespaces)
        title = title.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst("title:".count))
        }
        // Strip Markdown emphasis (e.g. "**feat: …**") so the PR title isn't
        // created with literal asterisks/backticks; titles render as plain text.
        title = ChatSession.stripMarkdownEmphasis(from: title)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespaces)
        title = normalizePullRequestTitle(title, fallbackTitle: fallbackTitle)
        title = truncatePullRequestTitleWords(title)
        if title.isEmpty { title = fallbackTitle }

        let body = lines[(firstIdx + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }

    private static func normalizePullRequestTitle(_ raw: String, fallbackTitle: String) -> String {
        var title = stripTrailingPullRequestTitlePunctuation(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !title.isEmpty else { return fallbackTitle }

        let pattern = #"^([A-Za-z]+)(\([^):\n]+\))?\s*:\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: title,
                range: NSRange(title.startIndex..<title.endIndex, in: title)
              ),
              let typeRange = Range(match.range(at: 1), in: title),
              let descriptionRange = Range(match.range(at: 3), in: title) else {
            return title
        }

        let type = title[typeRange].lowercased()
        let scope = Range(match.range(at: 2), in: title)
            .map { title[$0].lowercased() } ?? ""
        let description = lowercaseInitialPullRequestDescriptionWord(
            String(title[descriptionRange]).trimmingCharacters(in: .whitespaces)
        )

        title = "\(type)\(scope): \(description)"
        return stripTrailingPullRequestTitlePunctuation(title)
    }

    private static func stripTrailingPullRequestTitlePunctuation(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = CharacterSet(charactersIn: ".!?。！？")
        while let scalar = title.unicodeScalars.last, trailing.contains(scalar) {
            title.removeLast()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }

    private static func lowercaseInitialPullRequestDescriptionWord(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        var wordEnd = raw.startIndex
        while wordEnd < raw.endIndex, raw[wordEnd].isLetter {
            wordEnd = raw.index(after: wordEnd)
        }

        guard wordEnd > raw.startIndex else {
            guard let first = raw.first else { return raw }
            return first.lowercased() + String(raw.dropFirst())
        }

        let word = String(raw[..<wordEnd])
        if word.count > 1, word == word.uppercased() {
            return raw
        }
        return word.lowercased() + String(raw[wordEnd...])
    }
}
