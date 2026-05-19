import Foundation
import Testing
import RxCodeCore
@testable import RxCodeSync

@Suite("Mobile sync payloads")
struct PayloadTests {
    @Test("snapshot carries briefing and settings data")
    func snapshotCarriesBriefingAndSettingsData() throws {
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let settings = MobileSettingsSnapshot(
            selectedAgentProvider: .codex,
            selectedModel: "gpt-5.4",
            selectedACPClientId: "",
            selectedEffort: "high",
            permissionMode: .acceptEdits,
            summarizationProvider: "selectedClient",
            summarizationProviderDisplayName: "Thread Model",
            openAISummarizationEndpoint: "https://api.openai.com/v1",
            openAISummarizationModel: "",
            notificationsEnabled: true,
            focusMode: false,
            autoArchiveEnabled: true,
            archiveRetentionDays: 7,
            autoPreviewSettings: AttachmentAutoPreviewSettings(),
            availableEfforts: ["auto", "low", "medium", "high"]
        )
        let payload = Payload.snapshot(
            SnapshotPayload(
                projects: [],
                sessions: [],
                branchBriefings: [
                    MobileBranchBriefing(
                        projectId: projectId,
                        branch: "main",
                        briefing: "Current work summary",
                        updatedAt: Date(timeIntervalSince1970: 10)
                    )
                ],
                threadSummaries: [
                    MobileThreadSummary(
                        sessionId: "thread-1",
                        projectId: projectId,
                        branch: "main",
                        title: "Fix sync",
                        summary: "Added mobile sync fields",
                        updatedAt: Date(timeIntervalSince1970: 11)
                    )
                ],
                settings: settings
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .snapshot(let snapshot) = decoded else {
            Issue.record("Expected snapshot payload")
            return
        }

        #expect(snapshot.branchBriefings?.first?.briefing == "Current work summary")
        #expect(snapshot.threadSummaries?.first?.title == "Fix sync")
        #expect(snapshot.settings?.selectedAgentProvider == .codex)
        #expect(snapshot.settings?.permissionMode == .acceptEdits)
    }

    @Test("settings update round trips")
    func settingsUpdateRoundTrips() throws {
        let payload = Payload.settingsUpdate(
            MobileSettingsUpdatePayload(
                selectedEffort: "medium",
                permissionMode: .auto,
                focusMode: true
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .settingsUpdate(let update) = decoded else {
            Issue.record("Expected settings update payload")
            return
        }

        #expect(update.selectedEffort == "medium")
        #expect(update.permissionMode == .auto)
        #expect(update.focusMode == true)
    }
}
