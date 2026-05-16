import Testing
@testable import RxCodeCore

@Suite("parseGitHubOwnerRepo")
struct GitURLHelpersTests {

    @Test("HTTPS URL with .git suffix")
    func httpsWithGitSuffix() {
        #expect(parseGitHubOwnerRepo(from: "https://github.com/owner/repo.git") == "owner/repo")
    }

    @Test("HTTPS URL without .git suffix")
    func httpsWithoutGitSuffix() {
        #expect(parseGitHubOwnerRepo(from: "https://github.com/owner/repo") == "owner/repo")
    }

    @Test("SSH URL")
    func sshURL() {
        #expect(parseGitHubOwnerRepo(from: "git@github.com:owner/repo.git") == "owner/repo")
    }

    @Test("SSH URL without .git suffix")
    func sshURLWithoutGit() {
        #expect(parseGitHubOwnerRepo(from: "git@github.com:owner/repo") == "owner/repo")
    }

    @Test("Trailing slash stripped")
    func trailingSlash() {
        #expect(parseGitHubOwnerRepo(from: "https://github.com/owner/repo/") == "owner/repo")
    }

    @Test("Non-GitHub URL returns nil")
    func nonGitHub() {
        #expect(parseGitHubOwnerRepo(from: "https://gitlab.com/owner/repo.git") == nil)
    }

    @Test("Empty string returns nil")
    func emptyString() {
        #expect(parseGitHubOwnerRepo(from: "") == nil)
    }

    @Test("Only one path component returns nil")
    func oneComponent() {
        #expect(parseGitHubOwnerRepo(from: "https://github.com/owner") == nil)
    }

    @Test("Owner repo builds GitHub web URL")
    func ownerRepoBuildsWebURL() {
        #expect(gitHubWebURL(forOwnerRepo: "owner/repo")?.absoluteString == "https://github.com/owner/repo")
    }
}
