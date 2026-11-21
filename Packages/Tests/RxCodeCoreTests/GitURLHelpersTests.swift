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

    @Test("SSH URLs with a scheme can use either GitHub SSH host")
    func sshURLWithScheme() {
        #expect(parseGitHubOwnerRepo(from: "ssh://git@GitHub.com/Owner/repo.git") == "Owner/repo")
        #expect(parseGitHubOwnerRepo(from: "ssh://git@ssh.github.com:443/Owner/repo.git") == "Owner/repo")
    }

    @Test("Only the final .git suffix is stripped")
    func gitInRepositoryName() {
        #expect(parseGitHubOwnerRepo(from: "https://github.com/owner/project.git-tools.git") == "owner/project.git-tools")
    }

    @Test("Trailing slash stripped")
    func trailingSlash() {
        #expect(parseGitHubOwnerRepo(from: "https://github.com/owner/repo/") == "owner/repo")
    }

    @Test("Non-GitHub URL returns nil")
    func nonGitHub() {
        #expect(parseGitHubOwnerRepo(from: "https://gitlab.com/owner/repo.git") == nil)
        #expect(parseGitHubOwnerRepo(from: "https://github.com.example.net/owner/repo.git") == nil)
        #expect(parseGitHubOwnerRepo(from: "https://example.net/github.com/owner/repo.git") == nil)
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
