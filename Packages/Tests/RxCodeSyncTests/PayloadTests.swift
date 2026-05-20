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

    @Test("snapshot carries agent usage")
    func snapshotCarriesAgentUsage() throws {
        let payload = Payload.snapshot(
            SnapshotPayload(
                projects: [],
                sessions: [],
                usage: MobileUsageSnapshot(
                    claudeCode: RateLimitUsage(
                        fiveHourPercent: 42,
                        sevenDayPercent: 13,
                        fiveHourResetsAt: Date(timeIntervalSince1970: 100),
                        sevenDayResetsAt: Date(timeIntervalSince1970: 200)
                    ),
                    codex: RateLimitUsage(
                        fiveHourPercent: 7,
                        sevenDayPercent: 0,
                        twentyFourHourPercent: 55,
                        fiveHourResetsAt: nil,
                        sevenDayResetsAt: nil,
                        twentyFourHourResetsAt: Date(timeIntervalSince1970: 300)
                    )
                )
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .snapshot(let snapshot) = decoded else {
            Issue.record("Expected snapshot payload")
            return
        }

        #expect(snapshot.usage?.hasAnyUsage == true)
        #expect(snapshot.usage?.claudeCode?.fiveHourPercent == 42)
        #expect(snapshot.usage?.claudeCode?.sevenDayResetsAt == Date(timeIntervalSince1970: 200))
        #expect(snapshot.usage?.codex?.twentyFourHourPercent == 55)
    }

    @Test("snapshot without usage decodes to nil")
    func snapshotWithoutUsageDecodesToNil() throws {
        let payload = Payload.snapshot(SnapshotPayload(projects: [], sessions: []))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .snapshot(let snapshot) = decoded else {
            Issue.record("Expected snapshot payload")
            return
        }
        #expect(snapshot.usage == nil)
        #expect(snapshot.hostMetrics == nil)
    }

    @Test("snapshot carries host metrics")
    func snapshotCarriesHostMetrics() throws {
        let payload = Payload.snapshot(
            SnapshotPayload(
                projects: [],
                sessions: [],
                hostMetrics: HostMetricsSnapshot(
                    cpuUsagePercent: 37.5,
                    memoryUsedBytes: 8_000_000_000,
                    memoryTotalBytes: 16_000_000_000,
                    thermalState: .fair,
                    sampledAt: Date(timeIntervalSince1970: 500)
                )
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .snapshot(let snapshot) = decoded else {
            Issue.record("Expected snapshot payload")
            return
        }

        #expect(snapshot.hostMetrics?.cpuUsagePercent == 37.5)
        #expect(snapshot.hostMetrics?.memoryUsedBytes == 8_000_000_000)
        #expect(snapshot.hostMetrics?.thermalState == .fair)
        #expect(snapshot.hostMetrics?.memoryUsedPercent == 50)
    }

    @Test("host metrics tolerates an unknown thermal state")
    func hostMetricsToleratesUnknownThermalState() throws {
        // Simulate a newer desktop sending a thermal state this build predates.
        let json = """
        {"cpuUsagePercent":10,"memoryUsedBytes":1,"memoryTotalBytes":2,\
        "thermalState":"meltdown","sampledAt":0}
        """
        let decoded = try JSONDecoder().decode(HostMetricsSnapshot.self, from: Data(json.utf8))
        #expect(decoded.thermalState == .unknown)
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
