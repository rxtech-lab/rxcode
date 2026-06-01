import Foundation
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
        let raw = await generatePullRequestContent(briefing: briefing, branch: branch)
        let (title, body) = Self.parsePullRequestContent(raw, branch: branch)

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
        if title.isEmpty { title = fallbackTitle }

        let body = lines[(firstIdx + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }
}
