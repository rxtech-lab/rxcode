import Foundation
import Testing
import RxCodeCore
@testable import RxCodeSync

@Suite("Mobile sync payloads")
struct PayloadTests {
    @Test("thread changes carry optional full-file diff")
    func threadChangesCarryFullFileDiff() throws {
        let payload = Payload.threadChangesResult(
            ThreadChangesResultPayload(
                clientRequestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                sessionID: "thread-1",
                ok: true,
                turnEdits: [
                    SyncFileEdit(
                        path: "/tmp/example.swift",
                        name: "example.swift",
                        containsWrite: false,
                        hunks: [SyncEditHunk(oldString: "old", newString: "new")],
                        fullFileDiff: "--- before\n+++ after\n@@ full file @@\n-old\n+new"
                    )
                ],
                uncommitted: []
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .threadChangesResult(let result) = decoded else {
            Issue.record("Expected thread changes result payload")
            return
        }

        #expect(result.turnEdits.first?.fullFileDiff?.contains("@@ full file @@") == true)
    }

    @Test("thread changes decode when full-file diff is absent")
    func threadChangesDecodeWithoutFullFileDiff() throws {
        let json = """
        {
          "path": "/tmp/example.swift",
          "name": "example.swift",
          "containsWrite": false,
          "hunks": [
            { "oldString": "old", "newString": "new" }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SyncFileEdit.self, from: json)

        #expect(decoded.fullFileDiff == nil)
        #expect(decoded.hunks.first?.newString == "new")
    }

    @Test("pair request carries APNs environment")
    func pairRequestCarriesAPNsEnvironment() throws {
        let payload = Payload.pairRequest(
            PairRequestPayload(
                mobilePubkeyHex: String(repeating: "a", count: 64),
                displayName: "iPhone",
                platform: "iOS",
                appVersion: "1.2.3",
                apnsEnvironment: "sandbox"
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .pairRequest(let request) = decoded else {
            Issue.record("Expected pair request payload")
            return
        }

        #expect(request.apnsEnvironment == "sandbox")
    }

    @Test("push token carries provider and token")
    func pushTokenCarriesProviderAndToken() throws {
        let payload = Payload.pushToken(
            PushTokenPayload(provider: "fcm", token: "fcm-token")
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .pushToken(let token) = decoded else {
            Issue.record("Expected push token payload")
            return
        }

        #expect(token.provider == "fcm")
        #expect(token.token == "fcm-token")
        #expect(token.environment == nil)
    }

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
                ciStatuses: [
                    MobileProjectCIStatus(
                        projectId: projectId,
                        status: ProjectCIStatus(
                            owner: "rxlab",
                            repo: "rxcode",
                            branch: "main",
                            found: true,
                            overallState: .failure,
                            lastUpdated: "2026-05-31T00:00:00Z",
                            headSha: "abc123",
                            prNumber: 42,
                            prState: "open",
                            prUrl: "https://github.com/rxlab/rxcode/pull/42",
                            workflows: [],
                            failing: [
                                CIFailingWorkflow(
                                    workflowName: "Tests",
                                    htmlUrl: "https://github.com/rxlab/rxcode/actions/runs/1"
                                )
                            ]
                        )
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
        #expect(snapshot.ciStatuses?.first?.status.overallState == .failure)
        #expect(snapshot.ciStatuses?.first?.status.prNumber == 42)
        #expect(snapshot.settings?.selectedAgentProvider == .codex)
        #expect(snapshot.settings?.permissionMode == .acceptEdits)
    }

    @Test("session summary carries todo items")
    func sessionSummaryCarriesTodoItems() throws {
        let projectId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let todos = [
            TodoItem(id: 0, content: "Inspect Codex plan", activeForm: "Inspecting Codex plan", status: .completed),
            TodoItem(id: 1, content: "Sync mobile list", activeForm: "Syncing mobile list", status: .inProgress)
        ]
        let payload = Payload.snapshot(
            SnapshotPayload(
                projects: [],
                sessions: [
                    SessionSummary(
                        id: "thread-1",
                        projectId: projectId,
                        title: "Fix Codex todo sync",
                        updatedAt: Date(timeIntervalSince1970: 12),
                        isPinned: false,
                        isArchived: false,
                        progress: SessionProgressSnapshot(done: 1, total: 2, inProgress: true),
                        todos: todos
                    )
                ]
            )
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        guard case .snapshot(let snapshot) = decoded else {
            Issue.record("Expected snapshot payload")
            return
        }

        #expect(snapshot.sessions.first?.todos == todos)
        #expect(snapshot.sessions.first?.progress?.total == 2)
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
                        sevenDayPercent: 55,
                        fiveHourResetsAt: nil,
                        sevenDayResetsAt: Date(timeIntervalSince1970: 300)
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
        #expect(snapshot.usage?.codex?.sevenDayPercent == 55)
        #expect(snapshot.usage?.codex?.sevenDayResetsAt == Date(timeIntervalSince1970: 300))
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

    @Test("remote folder picker payloads round trip")
    func remoteFolderPickerPayloadsRoundTrip() throws {
        let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let request = Payload.folderTreeRequest(
            FolderTreeRequestPayload(
                clientRequestID: requestID,
                path: "/Users/test/Desktop",
                depth: 1
            )
        )

        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(Payload.self, from: requestData)
        guard case .folderTreeRequest(let folderRequest) = decodedRequest else {
            Issue.record("Expected folder tree request")
            return
        }
        #expect(folderRequest.clientRequestID == requestID)
        #expect(folderRequest.path == "/Users/test/Desktop")
        #expect(folderRequest.depth == 1)

        let result = Payload.folderTreeResult(
            FolderTreeResultPayload(
                clientRequestID: requestID,
                requestedPath: "/Users/test/Desktop",
                ok: true,
                root: RemoteFolderNode(
                    name: "Desktop",
                    path: "/Users/test/Desktop",
                    children: [
                        RemoteFolderNode(name: "RxCode", path: "/Users/test/Desktop/RxCode")
                    ]
                )
            )
        )

        let resultData = try JSONEncoder().encode(result)
        let decodedResult = try JSONDecoder().decode(Payload.self, from: resultData)
        guard case .folderTreeResult(let folderResult) = decodedResult else {
            Issue.record("Expected folder tree result")
            return
        }
        #expect(folderResult.ok)
        #expect(folderResult.root?.children.first?.name == "RxCode")
    }

    @Test("mobile create project payloads round trip")
    func mobileCreateProjectPayloadsRoundTrip() throws {
        let requestID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let projectID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!
        let request = Payload.createProjectRequest(
            CreateProjectRequestPayload(
                clientRequestID: requestID,
                path: "/Users/test/Desktop/RxCode"
            )
        )

        let requestData = try JSONEncoder().encode(request)
        let decodedRequest = try JSONDecoder().decode(Payload.self, from: requestData)
        guard case .createProjectRequest(let createRequest) = decodedRequest else {
            Issue.record("Expected create project request")
            return
        }
        #expect(createRequest.clientRequestID == requestID)
        #expect(createRequest.path == "/Users/test/Desktop/RxCode")

        let result = Payload.createProjectResult(
            CreateProjectResultPayload(
                clientRequestID: requestID,
                ok: true,
                project: Project(
                    id: projectID,
                    name: "RxCode",
                    path: "/Users/test/Desktop/RxCode"
                )
            )
        )

        let resultData = try JSONEncoder().encode(result)
        let decodedResult = try JSONDecoder().decode(Payload.self, from: resultData)
        guard case .createProjectResult(let createResult) = decodedResult else {
            Issue.record("Expected create project result")
            return
        }
        #expect(createResult.ok)
        #expect(createResult.project?.id == projectID)
        #expect(createResult.project?.name == "RxCode")
    }
}
