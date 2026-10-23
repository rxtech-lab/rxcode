import Foundation
import Testing
@testable import RxCodeCore

@Suite("Docs response contracts")
struct DocsModelsTests {
    @Test func mixedStandaloneAndGitHubProjectsDecode() throws {
        // Matches GET /api/v1/docs/repositories, including nullable GitHub fields.
        let data = Data(#"""
        {"items":[
          {"id":"standalone","name":"Product notes","displayName":"Product notes",
           "repositoryFullName":null,"installationId":null,"repositoryId":null},
          {"id":"github","repositoryFullName":"owner/repo","installationId":42,"repositoryId":12}
        ],"pagination":{"nextCursor":null,"hasMore":false}}
        """#.utf8)
        let response = try JSONDecoder().decode(DocsRepoListResponse.self, from: data)
        #expect(response.items.count == 2)
        #expect(response.items[0].repositoryFullName == nil)
        #expect(response.items[0].fullName == "Product notes")
        #expect(response.items[1].fullName == "owner/repo")
        #expect(response.pagination?.hasMore == false)
        let roundTrip = try JSONDecoder().decode(DocsRepoListResponse.self, from: JSONEncoder().encode(response))
        #expect(roundTrip.items == response.items)
    }

    @Test func missingRepositoryNameUsesProjectName() throws {
        let repo = try JSONDecoder().decode(DocsRepo.self, from: Data(#"{"id":"notes","name":"Notes"}"#.utf8))
        #expect(repo.repositoryFullName == nil)
        #expect(repo.fullName == "Notes")
        #expect(DocsRepo(id: "untitled").fullName == "Untitled project")
        #expect(DocsRepo(id: "named", name: "Name", displayName: "Display").fullName == "Display")
    }

    @Test func missingIdentityStillFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DocsRepo.self, from: Data(#"{"name":"Notes"}"#.utf8))
        }
    }
}
