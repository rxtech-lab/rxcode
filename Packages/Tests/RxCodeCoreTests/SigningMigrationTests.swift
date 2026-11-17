import Foundation
import Testing
@testable import RxCodeCore

struct SigningMigrationTests {
    @Test func organizationBuildKeepsExistingDataDirectory() {
        #expect(AppSupport.directoryName(for: "app.rxlab.flowcy.code") ==
                AppSupport.directoryName(for: "com.rxlab.RxCode"))
        #expect(AppSupport.directoryName(for: "com.idealapp.RxCode") == "RxCode")
        #expect(AppSupport.directoryName(for: "app.rxlab.flowcy.code.dev") == "RxCode.dev")
    }

    @Test func preferencesMigrateOnceWithoutOverwritingNewValues() throws {
        let source = "SigningMigrationTests.source.\(UUID().uuidString)"
        let destination = "SigningMigrationTests.destination.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: destination))
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }
        defaults.setPersistentDomain(["onboardingCompleted": true, "theme": "old"], forName: source)
        defaults.set("new", forKey: "theme")
        AppSupport.migrateSigningPreferencesIfNeeded(defaults: defaults, bundleID: "app.rxlab.flowcy.code", legacyDomain: source, destinationDomain: destination)
        #expect(defaults.string(forKey: "theme") == "new")
        #expect(defaults.bool(forKey: "onboardingCompleted"))
        defaults.set(false, forKey: "onboardingCompleted")
        AppSupport.migrateSigningPreferencesIfNeeded(defaults: defaults, bundleID: "app.rxlab.flowcy.code", legacyDomain: source, destinationDomain: destination)
        #expect(!defaults.bool(forKey: "onboardingCompleted"))
    }
}
