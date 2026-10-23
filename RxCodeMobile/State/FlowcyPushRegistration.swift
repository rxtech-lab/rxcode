import Foundation
import Observation
import RxCodeCore

/// Serializes device registration with token rotation and sign-out so a late PUT cannot recreate a removed device.
@MainActor @Observable
final class FlowcyPushRegistration {
    private(set) var isRegistered = false
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var environment: String?
    var isEnabled: Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    let deviceID: String
    let deviceName: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: (String, JSONValue) async throws -> Void
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var desiredAccount: String?
    @ObservationIgnored private var registeredFingerprint: String?
    @ObservationIgnored private var disconnecting = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    private let enabledKey = "flowcy.push.enabled"
    private let ownerKey = "flowcy.push.owner"

    init(defaults: UserDefaults = .standard, deviceName: String,
         transport: @escaping (String, JSONValue) async throws -> Void) {
        self.defaults = defaults
        self.deviceName = deviceName
        self.transport = transport
        if let saved = defaults.string(forKey: "flowcy.push.deviceID"), UUID(uuidString: saved) != nil { deviceID = saved }
        else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "flowcy.push.deviceID")
        }
    }

    func updateToken(_ token: String, environment: String, accountID: String?) async {
        guard ["sandbox", "production"].contains(environment),
              (64...200).contains(token.count), token.allSatisfy(\.isHexDigit) else { return }
        self.token = token
        self.environment = environment
        await synchronize(accountID: accountID)
    }

    func synchronize(accountID: String?) async {
        guard !disconnecting else { return }
        desiredAccount = accountID
        guard isEnabled, accountID != nil, token != nil else { return }
        if let worker { await worker.value; return }
        let task = Task { await registerLatest() }
        worker = task
        await task.value
        worker = nil
    }

    private func registerLatest() async {
        isWorking = true
        defer { isWorking = false }
        while let account = desiredAccount, let token, let environment, isEnabled {
            let fingerprint = account + "|" + environment + "|" + token
            guard fingerprint != registeredFingerprint else { return }
            if let previousOwner = defaults.string(forKey: ownerKey), previousOwner != account {
                isRegistered = false
                error = "This device is registered to another Flowcy account. Sign in to that account and disconnect notifications first."
                return
            }
            // Persist only account/device identifiers. Neither push tokens nor credentials are persisted or logged here.
            defaults.set(account, forKey: ownerKey)
            do {
                try await transport("PUT", .object([
                    "id": .string(deviceID), "name": .string(deviceName), "provider": .string("apns"),
                    "token": .string(token), "environment": .string(environment)
                ]))
                registeredFingerprint = fingerprint
                isRegistered = desiredAccount == account
                error = nil
            } catch {
                isRegistered = false
                self.error = "Could not register this device with Flowcy. Try again while signed in."
                return
            }
        }
    }

    /// Credentials must remain available until this completes. A failed removal is surfaced to the caller.
    func disconnect(accountID: String?, disable: Bool = false) async throws {
        guard !disconnecting else { throw FlowcyError.message("Notification disconnection is already in progress.") }
        disconnecting = true
        defer { disconnecting = false }
        desiredAccount = nil
        if let worker { await worker.value }
        guard let owner = defaults.string(forKey: ownerKey), owner == accountID else {
            isRegistered = false
            registeredFingerprint = nil
            if disable { defaults.set(false, forKey: enabledKey) }
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await transport("DELETE", .object(["id": .string(deviceID)]))
            defaults.removeObject(forKey: ownerKey)
            registeredFingerprint = nil
            isRegistered = false
            error = nil
            if disable { defaults.set(false, forKey: enabledKey) }
        } catch {
            self.error = "Could not disconnect this device from Flowcy. Retry before signing out."
            throw error
        }
    }

    func enable(accountID: String?) async {
        defaults.set(true, forKey: enabledKey)
        registeredFingerprint = nil
        await synchronize(accountID: accountID)
    }

    func sessionEnded() {
        desiredAccount = nil
        registeredFingerprint = nil
        isRegistered = false
    }
}
