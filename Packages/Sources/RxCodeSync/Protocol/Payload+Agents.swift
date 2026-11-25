import Foundation
import RxCodeCore

// MARK: - Agent hub

/// One agent as the phone's Chat tab lists it.
public struct AgentHubAgent: Codable, Sendable, Equatable, Identifiable {
    public var profile: AgentProfile
    /// "Opus · high" style label of the agent's model.
    public var modelLabel: String
    /// The agent's conversation thread, when it has one.
    public var primarySessionId: String?
    public var lastMessagePreview: String?
    public var lastActivityAt: Date?
    public var isStreaming: Bool
    /// The agent finished a reply nobody has read yet.
    public var hasUnread: Bool
    /// A computer-use tool is running in one of the agent's threads, so the
    /// live screen is worth watching.
    public var isUsingComputer: Bool

    public var id: UUID { profile.id }

    public init(
        profile: AgentProfile,
        modelLabel: String,
        primarySessionId: String? = nil,
        lastMessagePreview: String? = nil,
        lastActivityAt: Date? = nil,
        isStreaming: Bool = false,
        hasUnread: Bool = false,
        isUsingComputer: Bool = false
    ) {
        self.profile = profile
        self.modelLabel = modelLabel
        self.primarySessionId = primarySessionId
        self.lastMessagePreview = lastMessagePreview
        self.lastActivityAt = lastActivityAt
        self.isStreaming = isStreaming
        self.hasUnread = hasUnread
        self.isUsingComputer = isUsingComputer
    }

    private enum CodingKeys: String, CodingKey {
        case profile, modelLabel, primarySessionId, lastMessagePreview, lastActivityAt, isStreaming, hasUnread, isUsingComputer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(AgentProfile.self, forKey: .profile)
        modelLabel = (try? c.decodeIfPresent(String.self, forKey: .modelLabel)) ?? ""
        primarySessionId = try? c.decodeIfPresent(String.self, forKey: .primarySessionId)
        lastMessagePreview = try? c.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        lastActivityAt = try? c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        isStreaming = (try? c.decodeIfPresent(Bool.self, forKey: .isStreaming)) ?? false
        hasUnread = (try? c.decodeIfPresent(Bool.self, forKey: .hasUnread)) ?? false
        isUsingComputer = (try? c.decodeIfPresent(Bool.self, forKey: .isUsingComputer)) ?? false
    }
}

/// Everything the phone shows about the Mac's agents.
public struct AgentHubSnapshot: Codable, Sendable, Equatable {
    public var agents: [AgentHubAgent]
    public var memory: [AgentMemoryNote]
    public var jobs: [AgentJob]
    /// Schedules owned by agents.
    public var schedules: [ScheduledTask]
    public var remoteAccess: AgentRemoteAccessPolicy
    /// Whether the Mac granted Screen Recording and Accessibility, which live
    /// screen sharing and remote control need.
    public var canCaptureScreen: Bool
    public var canControlInput: Bool

    public init(
        agents: [AgentHubAgent] = [],
        memory: [AgentMemoryNote] = [],
        jobs: [AgentJob] = [],
        schedules: [ScheduledTask] = [],
        remoteAccess: AgentRemoteAccessPolicy = AgentRemoteAccessPolicy(),
        canCaptureScreen: Bool = false,
        canControlInput: Bool = false
    ) {
        self.agents = agents
        self.memory = memory
        self.jobs = jobs
        self.schedules = schedules
        self.remoteAccess = remoteAccess
        self.canCaptureScreen = canCaptureScreen
        self.canControlInput = canControlInput
    }

    private enum CodingKeys: String, CodingKey {
        case agents, memory, jobs, schedules, remoteAccess, canCaptureScreen, canControlInput
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = (try? c.decodeIfPresent([AgentHubAgent].self, forKey: .agents)) ?? []
        memory = (try? c.decodeIfPresent([AgentMemoryNote].self, forKey: .memory)) ?? []
        jobs = (try? c.decodeIfPresent([AgentJob].self, forKey: .jobs)) ?? []
        schedules = (try? c.decodeIfPresent([ScheduledTask].self, forKey: .schedules)) ?? []
        remoteAccess = (try? c.decodeIfPresent(AgentRemoteAccessPolicy.self, forKey: .remoteAccess)) ?? AgentRemoteAccessPolicy()
        canCaptureScreen = (try? c.decodeIfPresent(Bool.self, forKey: .canCaptureScreen)) ?? false
        canControlInput = (try? c.decodeIfPresent(Bool.self, forKey: .canControlInput)) ?? false
    }

    public func agent(id: UUID) -> AgentHubAgent? { agents.first { $0.id == id } }
    public func memory(for agentId: UUID) -> [AgentMemoryNote] {
        memory.filter { $0.agentId == agentId }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public func jobs(for agentId: UUID) -> [AgentJob] {
        jobs.filter { $0.agentId == agentId }.sorted { $0.createdAt > $1.createdAt }
    }
    public func schedules(for agentId: UUID) -> [ScheduledTask] {
        schedules.filter { $0.agentId == agentId }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Desktop → mobile: the current agent hub. Sent with every snapshot and
/// whenever an agent, note, job or schedule changes.
public struct AgentHubUpdatePayload: Codable, Sendable {
    public let snapshot: AgentHubSnapshot
    /// Monotonic per desktop launch, so a delayed older update is ignored.
    public let seq: UInt64?

    public init(snapshot: AgentHubSnapshot, seq: UInt64? = nil) {
        self.snapshot = snapshot
        self.seq = seq
    }
}

/// Mobile → desktop: one change or action in the agent hub.
public struct AgentRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case refresh
        case createAgent
        case updateAgent
        case deleteAgent
        /// Returns the agent's conversation thread, creating none.
        case openConversation
        /// Starts a fresh conversation thread for the next message.
        case newConversation
        /// Sends `text` to the agent's conversation, starting it when needed.
        case sendMessage
        case addMemory
        case updateMemory
        case deleteMemory
        case upsertSchedule
        case deleteSchedule
        case setScheduleEnabled
        case runSchedule
        case cancelJob
        /// An operation from a newer phone build.
        case unsupported

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Operation(rawValue: raw) ?? .unsupported
        }
    }

    public let clientRequestID: UUID
    public let operation: Operation
    public var agent: AgentProfile?
    public var agentID: UUID?
    public var text: String?
    public var memory: AgentMemoryNote?
    public var memoryID: UUID?
    public var schedule: ScheduledTask?
    public var scheduleID: UUID?
    public var enabled: Bool?
    public var jobID: UUID?

    public init(
        clientRequestID: UUID = UUID(),
        operation: Operation,
        agent: AgentProfile? = nil,
        agentID: UUID? = nil,
        text: String? = nil,
        memory: AgentMemoryNote? = nil,
        memoryID: UUID? = nil,
        schedule: ScheduledTask? = nil,
        scheduleID: UUID? = nil,
        enabled: Bool? = nil,
        jobID: UUID? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.agent = agent
        self.agentID = agentID
        self.text = text
        self.memory = memory
        self.memoryID = memoryID
        self.schedule = schedule
        self.scheduleID = scheduleID
        self.enabled = enabled
        self.jobID = jobID
    }
}

/// Desktop → mobile: how an `AgentRequestPayload` ended.
public struct AgentResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let ok: Bool
    public let error: String?
    public let agentID: UUID?
    /// The conversation thread a send or open resolved to.
    public let sessionID: String?

    public init(clientRequestID: UUID, ok: Bool, error: String? = nil, agentID: UUID? = nil, sessionID: String? = nil) {
        self.clientRequestID = clientRequestID
        self.ok = ok
        self.error = error
        self.agentID = agentID
        self.sessionID = sessionID
    }
}

// MARK: - Screen sharing and remote control

/// A display the phone can watch.
public struct ScreenShareDisplay: Codable, Sendable, Hashable, Identifiable {
    public let id: UInt32
    public let name: String
    /// Size in points.
    public let width: Int
    public let height: Int

    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }
}

/// Mobile → desktop: start, steer or stop watching the Mac's screen.
public struct ScreenShareRequestPayload: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case start
        case stop
        /// Sent while the viewer is open so the Mac ends abandoned sessions.
        case keepAlive
        case selectDisplay
        case requestControl
        case releaseControl
        case unsupported

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Action(rawValue: raw) ?? .unsupported
        }
    }

    public let action: Action
    /// The session the action applies to. `nil` on `start`.
    public let sessionID: UUID?
    public let displayID: UInt32?
    /// Longest edge of a frame, in pixels.
    public let maxDimension: Int?
    public let framesPerSecond: Double?
    /// The agent whose work the user is watching, for the Mac's indicator.
    public let agentID: UUID?

    public init(
        action: Action,
        sessionID: UUID? = nil,
        displayID: UInt32? = nil,
        maxDimension: Int? = nil,
        framesPerSecond: Double? = nil,
        agentID: UUID? = nil
    ) {
        self.action = action
        self.sessionID = sessionID
        self.displayID = displayID
        self.maxDimension = maxDimension
        self.framesPerSecond = framesPerSecond
        self.agentID = agentID
    }
}

/// Desktop → mobile: where a screen-sharing session stands.
public struct ScreenShareStatePayload: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case starting
        case active
        case stopped
        /// The Mac's Remote Access settings don't allow this.
        case denied
        case failed

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .failed
        }
    }

    public let sessionID: UUID?
    public let status: Status
    public let controlGranted: Bool
    public let displays: [ScreenShareDisplay]
    public let activeDisplayID: UInt32?
    public let message: String?

    public init(
        sessionID: UUID?,
        status: Status,
        controlGranted: Bool = false,
        displays: [ScreenShareDisplay] = [],
        activeDisplayID: UInt32? = nil,
        message: String? = nil
    ) {
        self.sessionID = sessionID
        self.status = status
        self.controlGranted = controlGranted
        self.displays = displays
        self.activeDisplayID = activeDisplayID
        self.message = message
    }
}

/// Desktop → mobile: one JPEG frame of the shared display.
public struct ScreenFramePayload: Codable, Sendable {
    public let sessionID: UUID
    public let seq: UInt64
    public let displayID: UInt32
    public let jpeg: Data
    /// Pixel size of the JPEG.
    public let width: Int
    public let height: Int
    /// Pointer position as fractions of the display, top-left origin.
    public let cursorX: Double?
    public let cursorY: Double?
    public let capturedAt: Date

    public init(
        sessionID: UUID,
        seq: UInt64,
        displayID: UInt32,
        jpeg: Data,
        width: Int,
        height: Int,
        cursorX: Double? = nil,
        cursorY: Double? = nil,
        capturedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.seq = seq
        self.displayID = displayID
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.capturedAt = capturedAt
    }
}

/// Mobile → desktop: a frame arrived. The Mac keeps only a couple of frames in
/// flight, so a slow link drops frames instead of queueing seconds of video.
public struct ScreenFrameAckPayload: Codable, Sendable {
    public let sessionID: UUID
    public let seq: UInt64

    public init(sessionID: UUID, seq: UInt64) {
        self.sessionID = sessionID
        self.seq = seq
    }
}

/// Mobile → desktop: pointer and keyboard input for a session with control.
/// Coordinates are fractions of the shared display, top-left origin.
public struct RemoteInputPayload: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case click
        case doubleClick
        case rightClick
        case move
        case drag
        case scroll
        case text
        case key
        case unsupported

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unsupported
        }
    }

    public let sessionID: UUID
    /// Increases per event so a duplicate delivery is applied once.
    public let seq: UInt64
    public let kind: Kind
    public let x: Double?
    public let y: Double?
    public let toX: Double?
    public let toY: Double?
    /// Scroll distance in points; positive scrolls content up/left.
    public let deltaX: Double?
    public let deltaY: Double?
    public let text: String?
    /// A key combination such as `cmd+t` or `return`; see `RemoteKey`.
    public let key: String?

    public init(
        sessionID: UUID,
        seq: UInt64,
        kind: Kind,
        x: Double? = nil,
        y: Double? = nil,
        toX: Double? = nil,
        toY: Double? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        text: String? = nil,
        key: String? = nil
    ) {
        self.sessionID = sessionID
        self.seq = seq
        self.kind = kind
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.text = text
        self.key = key
    }

    /// Longest text a single event may type.
    public static let textLimit = 2000

    /// Whether every coordinate is a finite fraction and the text fits.
    public var isWellFormed: Bool {
        let fractions = [x, y, toX, toY].compactMap { $0 }
        guard fractions.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        let deltas = [deltaX, deltaY].compactMap { $0 }
        guard deltas.allSatisfy({ $0.isFinite && abs($0) <= 5000 }) else { return false }
        if let text, text.count > Self.textLimit { return false }
        switch kind {
        case .click, .doubleClick, .rightClick, .move: return x != nil && y != nil
        case .drag: return x != nil && y != nil && toX != nil && toY != nil
        case .scroll: return deltaX != nil || deltaY != nil
        case .text: return !(text ?? "").isEmpty
        case .key: return key.flatMap(RemoteKey.parse) != nil
        case .unsupported: return false
        }
    }
}
