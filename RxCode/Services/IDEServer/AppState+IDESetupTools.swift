import Foundation
import RxCodeCore

extension AppState {
    @MainActor
    func handleSearchDocs(arguments: JSONValue) async throws -> JSONValue {
        guard let query = arguments["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'query'")
        }
        let repo = arguments["repository"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = arguments["limit"]?.numberValue ?? 10
        guard requested.isFinite else { throw IDEToolError.invalidArguments("limit must be finite") }
        let requestedLimit = Int(max(1, min(requested, 50)))
        let limit = max(1, min(requestedLimit, 50))
        do {
            let hits = try await docs.search(query: query, repo: (repo?.isEmpty == false) ? repo : nil, limit: limit)
            let entries: [JSONValue] = hits.map { hit in
                var obj: [String: JSONValue] = ["doc_id": .string(hit.docId)]
                if let id = hit.docsRepositoryId { obj["docs_repository_id"] = .string(id) }
                if let version = hit.version { obj["version"] = .number(Double(version)) }
                if let repository = hit.repository { obj["repository"] = .string(repository) }
                if let snippet = hit.snippet { obj["snippet"] = .string(snippet) }
                if let score = hit.score { obj["score"] = .number(score) }
                if let link = hit.originalLink { obj["original_link"] = .string(link) }
                return .object(obj)
            }
            return jsonTextResult(.object([
                "items": .array(entries), "fetched_at": .string(Date().ISO8601Format()),
                "source": .string("flowcy_semantic_index"),
                "freshness": .string("Indexed content may lag uploads. Use ide__flowcy docsGetDocument with docs_repository_id as repoId and doc_id as docId to retrieve the current stored version and embedding status.")
            ]))
        } catch {
            return safeFlowcyFailure(error)
        }
    }

    @MainActor
    func handleSetupDocsSecret(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        // Prefer an explicit `owner/repo`; otherwise fall back to the repo linked
        // to the calling session's project.
        let explicit = arguments["repository"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo: String
        if let explicit, !explicit.isEmpty {
            repo = explicit
        } else if let thread = threadStore.fetch(id: sessionKey),
                  let linked = projects.first(where: { $0.id == thread.projectId })?.gitHubRepo,
                  !linked.isEmpty {
            repo = linked
        } else {
            throw IDEToolError.invalidArguments(
                "No 'repository' given and the current project has no linked GitHub repo. Pass repository as 'owner/repo'."
            )
        }
        // The install endpoint 404s on unregistered repos, so register first if
        // needed (these throw IDEToolError with their own messages — keep them
        // outside the catch below so they aren't re-wrapped).
        let registered: Bool
        do { registered = try await ensureDocsRepoRegistered(repo) }
        catch let error as IDEToolError { throw error }
        catch { return safeFlowcyFailure(error) }
        do {
            let result = try await docs.installGithubSecret(repoId: repo)
            return jsonTextResult(.object([
                "installed": .bool(true),
                "registered": .bool(registered),
                "secret_name": .string(result.secretName),
                "repository": .string(result.repositoryFullName),
            ]))
        } catch {
            return safeFlowcyFailure(error)
        }
    }

    /// Ensures `repo` (an `owner/repo`) is registered with the docs service,
    /// registering it if not. Returns true when it had to register it. Throws a
    /// descriptive `IDEToolError` when the repo isn't accessible to the GitHub
    /// App (so it can't be registered).
    @MainActor
    private func ensureDocsRepoRegistered(_ repo: String) async throws -> Bool {
        if let status = try? await docs.statuses(forRepos: [repo]).first, status.hasDocs {
            return false
        }
        guard let managed = try await findManagedRepo(fullName: repo) else {
            throw IDEToolError.handlerFailed(
                "\(repo) isn't set up for docs and isn't accessible to the RxLab GitHub App. Install the GitHub App on this repository, then retry."
            )
        }
        _ = try await docs.addRepository(
            AddDocsRepoBody(
                installationId: managed.installationId,
                repositoryId: managed.id,
                repositoryFullName: managed.fullName
            )
        )
        return true
    }

    @MainActor
    func handleSetupRelease(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        guard arguments["release_token"] == nil else {
            throw IDEToolError.invalidArguments("Enter release credentials in native release setup, not MCP. Use ide__flowcy releaseTokenSetup.")
        }
        // Prefer an explicit `owner/repo`; otherwise fall back to the repo linked
        // to the calling session's project.
        let explicit = arguments["repository"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo: String
        if let explicit, !explicit.isEmpty {
            repo = explicit
        } else if let thread = threadStore.fetch(id: sessionKey),
                  let linked = projects.first(where: { $0.id == thread.projectId })?.gitHubRepo,
                  !linked.isEmpty {
            repo = linked
        } else {
            throw IDEToolError.invalidArguments(
                "No 'repository' given and the current project has no linked GitHub repo. Pass repository as 'owner/repo'."
            )
        }
        // Register (and scan workflows) first if needed; throws a descriptive
        // IDEToolError when the repo isn't accessible to the GitHub App.
        let registered: Bool
        do { registered = try await ensureReleaseRepoRegistered(repo) }
        catch let error as IDEToolError { throw error }
        catch { return safeFlowcyFailure(error) }

        return jsonTextResult(.object([
            "registered": .bool(registered), "secret_installed": .bool(false), "repository": .string(repo),
            "note": .string("Repository registered and workflows scanned. Use ide__flowcy releaseTokenSetup with the local project_id to open native release setup. Enter RELEASE_TOKEN only in that UI; never send credentials through MCP.")
        ]))
    }

    /// Ensures `repo` (an `owner/repo`) is registered with the release service,
    /// registering it if not. Returns true when it had to register it. Throws a
    /// descriptive `IDEToolError` when the repo isn't accessible to the GitHub
    /// App (so it can't be registered).
    @MainActor
    private func ensureReleaseRepoRegistered(_ repo: String) async throws -> Bool {
        if let status = try? await release.statuses(forRepos: [repo]).first, status.isManaged {
            return false
        }
        guard let managed = try await findManagedRepo(fullName: repo) else {
            throw IDEToolError.handlerFailed(
                "\(repo) isn't set up for releases and isn't accessible to the RxLab GitHub App. Install the GitHub App on this repository, then retry."
            )
        }
        _ = try await release.addRepository(
            AddReleaseRepoBody(
                installationId: managed.installationId,
                repositoryId: managed.id,
                repositoryFullName: managed.fullName
            )
        )
        return true
    }

    /// Finds the accessible GitHub repo matching `fullName` (`owner/repo`) in the
    /// secrets `repositories/all` listing — the source of the `installationId` +
    /// `repositoryId` the docs add-repo API needs. Pages defensively in case the
    /// search filter returns more than one page.
    @MainActor
    private func findManagedRepo(fullName: String) async throws -> SecretsManagedRepo? {
        let target = fullName.lowercased()
        var cursor: String?
        repeat {
            let page = try await secrets.listManagedRepositories(search: fullName, cursor: cursor, pageSize: 100)
            if let match = page.items.first(where: { $0.fullName.lowercased() == target }) {
                return match
            }
            cursor = page.pagination.hasMore ? page.pagination.nextCursor : nil
        } while cursor != nil
        return nil
    }
}
