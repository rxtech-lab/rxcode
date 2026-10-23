import Foundation
import Observation
import RxCodeCore

/// Tools use the same account session as the dashboard and chat API.
@MainActor @Observable
final class FlowcyToolsState {
    private(set) var tools: [FlowcyTool] = []
    private(set) var isConnected = false
    private(set) var isBusy = false
    var error: String?
    let client: FlowcyMCPClient
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connection: Task<Void, Never>?

    init(client: FlowcyMCPClient = FlowcyMCPClient()) { self.client = client }

    func connect() async {
        if let connection { await connection.value; return }
        let current = generation
        let task = Task { await discover(current: current) }
        connection = task
        await task.value
        if generation == current { connection = nil }
    }

    private func discover(current: UUID) async {
        isBusy = true
        error = nil
        isConnected = false
        defer { if generation == current { isBusy = false } }
        do {
            let discovered = try await client.discover()
            try Task.checkCancellation()
            guard current == generation else { return }
            tools = discovered
            isConnected = true
        } catch is CancellationError { }
        catch {
            guard current == generation else { return }
            tools = []
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        generation = UUID()
        connection?.cancel()
        connection = nil
        tools = []
        isConnected = false
        isBusy = false
        error = nil
        await client.reset()
    }

    func call(_ tool: FlowcyTool, arguments: JSONValue) async throws -> JSONValue {
        let current = generation
        do {
            let result = try await client.call(tool.name, arguments: arguments)
            guard current == generation else { throw CancellationError() }
            return result
        } catch FlowcyError.signIn {
            isConnected = false
            tools = []
            throw FlowcyError.signIn
        }
    }
}
