import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class BriefingNotificationStateTests: XCTestCase {

    private var appState: AppState!

    override func setUp() async throws {
        appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        try await appState.notificationStore.saveSettings(BriefingNotificationSettings())
        await appState.loadBriefingNotificationSettings()
    }

    override func tearDown() async throws {
        appState = nil
    }

    func testSettingsChangesPersistAndReload() async throws {
        let projectId = UUID()
        appState.updateBriefingNotificationSettings {
            $0.recipient = "team@example.com"
            $0.defaultMode = .always
            $0.projectModes[projectId] = .never
        }
        XCTAssertEqual(appState.briefingNotificationSettings.mode(for: projectId), .never)

        let deadline = Date.now.addingTimeInterval(5)
        var stored = await appState.notificationStore.settings()
        while stored.recipient == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            stored = await appState.notificationStore.settings()
        }
        XCTAssertEqual(stored, appState.briefingNotificationSettings)

        appState.briefingNotificationSettings = BriefingNotificationSettings()
        await appState.loadBriefingNotificationSettings()
        XCTAssertEqual(appState.briefingNotificationSettings.recipient, "team@example.com")
        XCTAssertEqual(appState.briefingNotificationSettings.defaultMode, .always)
    }

    func testPublishHookIgnoresDraftsAndProjectsThatNeverSend() {
        let projectId = UUID()
        appState.updateBriefingNotificationSettings { $0.projectModes[projectId] = .never }

        appState.briefingWasPublished(BriefingDocument(title: "Draft", isDraft: true), sessionKey: "s1")
        appState.briefingWasPublished(BriefingDocument(title: "Muted", projectId: projectId), sessionKey: "s1")
        XCTAssertTrue(appState.briefingNotificationsInFlight.isEmpty)

        appState.updateBriefingNotificationSettings { $0.isEnabled = false }
        appState.briefingWasPublished(BriefingDocument(title: "Off"), sessionKey: "s1")
        XCTAssertTrue(appState.briefingNotificationsInFlight.isEmpty)
    }

    func testPublishHookTracksEligibleBriefingOnce() {
        let briefing = BriefingDocument(title: "Weekly report")
        appState.briefingWasPublished(briefing, sessionKey: "s1")
        appState.briefingWasPublished(briefing, sessionKey: "s1")
        XCTAssertEqual(appState.briefingNotificationsInFlight, [briefing.id])
    }

    func testSessionKeysIncludeRenamedSession() {
        appState.sessionIdRedirect["pending-1"] = "cli-1"
        XCTAssertEqual(appState.notificationSessionKeys("pending-1"), ["pending-1", "cli-1"])
        XCTAssertEqual(appState.notificationSessionKeys(nil), [])
    }

    func testScheduledRunNotificationMatchesRenamedSession() {
        appState.scheduledRunNotificationSessions["pending-2"] = .completionReport
        appState.sessionIdRedirect["pending-2"] = "cli-2"
        XCTAssertEqual(appState.scheduledRunNotification(forSessions: ["cli-2"]), .completionReport)
        XCTAssertEqual(appState.scheduledRunNotification(forSessions: ["pending-2"]), .completionReport)
        XCTAssertNil(appState.scheduledRunNotification(forSessions: ["other"]))
    }

    func testGrantedScopesAreReadFromTheAccessToken() {
        func jwt(_ claims: String) -> String {
            let payload = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
            return "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"
        }
        XCTAssertEqual(RxAuthService.grantedScopes(in: jwt(#"{"sub":"u","scope":"openid"}"#)), ["openid"])
        XCTAssertEqual(
            RxAuthService.grantedScopes(in: jwt(#"{"scope":"openid read:profile read:email"}"#)),
            Set(RxAuthService.requestedScopes)
        )
        XCTAssertNil(RxAuthService.grantedScopes(in: jwt(#"{"sub":"u"}"#)))
        XCTAssertNil(RxAuthService.grantedScopes(in: "opaque-token"))
    }
}
