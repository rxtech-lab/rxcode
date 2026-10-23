import Foundation
import Testing
@testable import RxCodeCore

@Suite("Repository automation contracts")
struct RepositoryAutomationModelsTests {
    @Test func automationResponseDecodes() throws {
        // Matches GET /api/v1/watched-repositories/{id}/automation (drizzle dates serialize as ISO strings).
        let data = Data(#"""
        {"settings":{"dependenciesEnabled":true,"dependencyCiRepair":true,"dependencyAutoMerge":false,
          "ciAutoMerge":true,"dependencySecurityEnabled":true,"ciSecurityEnabled":false,
          "dependencyNotifications":true,"ciNotifications":false,
          "targets":[{"directory":"","manager":"auto"},{"directory":"apps/web","manager":"bun"}]},
         "runs":[{"id":"r1","watchedRepositoryId":"w","kind":"dependencies","status":"queued","prUrls":[],
          "findings":[],"error":null,"startedAt":"2026-10-23T10:00:00.000Z","completedAt":null},
          {"id":"r2","watchedRepositoryId":"w","kind":"ci-security","status":"error",
          "prUrls":["https://github.com/o/r/pull/7"],
          "findings":[{"id":"GHSA-1","package":"lodash","version":"4.0.0","path":"package-lock.json","url":"https://osv.dev/vulnerability/GHSA-1"}],
          "error":"Notification failed","startedAt":"2026-10-22T10:00:00Z","completedAt":"2026-10-22T10:05:00Z"}],
         "scannerConfigured":true}
        """#.utf8)
        let response = try JSONDecoder().decode(RepositoryAutomationResponse.self, from: data)
        #expect(response.settings.ciAutoMerge)
        #expect(response.settings.targets == [DependencyTarget(), DependencyTarget(directory: "apps/web", manager: .bun)])
        #expect(response.runs[0].isActive)
        #expect(response.runs[0].startedDate != nil)
        #expect(response.runs[1].findings?.first?.package == "lodash")
        #expect(!response.runs[1].isDependencies)
    }

    @Test func settingsEncodeOnlyServerKeys() throws {
        // The server schema is strict, so extra keys would be rejected.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RepositoryAutomationSettings())) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == [
            "dependenciesEnabled", "dependencyCiRepair", "dependencyAutoMerge", "ciAutoMerge",
            "dependencySecurityEnabled", "ciSecurityEnabled", "dependencyNotifications", "ciNotifications", "targets",
        ])
    }

    @Test func missingKeysUseServerDefaultsAndUnknownManagersFallBack() throws {
        let settings = try JSONDecoder().decode(RepositoryAutomationSettings.self,
                                                from: Data(#"{"targets":[{"directory":"x","manager":"cargo"}]}"#.utf8))
        #expect(!settings.dependenciesEnabled)
        #expect(settings.dependencyCiRepair)
        #expect(settings.targets == [DependencyTarget(directory: "x", manager: .auto)])
    }

    @Test func directoryValidationMatchesServerRule() {
        #expect(RepositoryAutomationSettings.isValidDirectory(""))
        #expect(RepositoryAutomationSettings.isValidDirectory("packages/api-v2_beta.1"))
        #expect(!RepositoryAutomationSettings.isValidDirectory("../secrets"))
        #expect(!RepositoryAutomationSettings.isValidDirectory("a/.git"))
        #expect(!RepositoryAutomationSettings.isValidDirectory("a//b"))
        #expect(!RepositoryAutomationSettings.isValidDirectory("apps/*"))
        #expect(!RepositoryAutomationSettings.isValidDirectory("café"))
    }
}
