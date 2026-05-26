import Foundation
import os.log
import RxCodeCore
import RxCodeSync

// MARK: - APNs / FCM Push Fan-out

extension MobileSyncService {
    func fanoutPush(_ payload: NotificationPayload) async {
        let devices = pairedDevices.filter { Self.pushToken(for: $0)?.isEmpty == false }
        guard !devices.isEmpty else { return }

        // Each push is an independent HTTPS POST to the relay's `/push`
        // endpoint. On a remote relay, RTT dominates (100-300ms per device),
        // so serial fan-out scales linearly with paired-device count. Run
        // them concurrently — the per-device error path already swallows
        // failures, so one slow/failing device cannot poison the rest.
        struct Target {
            let device: PairedDevice
            let pushURL: URL
            let provider: String
        }
        var targets: [Target] = []
        for device in devices {
            guard let relayURLString = device.relayURL,
                  let relayURL = URL(string: relayURLString),
                  let pushURL = Self.pushEndpointURL(from: relayURL) else {
                logger.error("[Push] cannot derive push endpoint for device=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                continue
            }
            targets.append(Target(device: device, pushURL: pushURL, provider: Self.pushProvider(for: device)))
        }

        let logger = self.logger
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        switch target.provider {
                        case "fcm":
                            try await self.sendFCMPush(payload, to: target.device, pushURL: target.pushURL)
                        default:
                            try await self.sendAPNsPush(payload, to: target.device, pushURL: target.pushURL)
                        }
                    } catch {
                        logger.error("[Push] fan-out failed provider=\(target.provider, privacy: .public) deviceKey=\(String(target.device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Best-effort APNs fan-out: submit one encrypted alert per paired device
    /// that has registered a push token. Per-device failures are logged and
    /// swallowed — the live channel above remains the primary path.
    ///
    /// Each device's push is an independent HTTPS POST; run them concurrently
    /// so a slow remote-relay RTT for one device does not stall the others.
    func fanoutAPNs(_ payload: NotificationPayload) async {
        let devices = pairedDevices.filter { ($0.apnsToken?.isEmpty == false) }
        guard !devices.isEmpty else { return }

        var targets: [(device: PairedDevice, pushURL: URL)] = []
        for device in devices {
            guard let relayURLString = device.relayURL,
                  let relayURL = URL(string: relayURLString),
                  let pushURL = Self.pushEndpointURL(from: relayURL) else {
                logger.error("[APNs] cannot derive push endpoint for device=\(String(device.pubkeyHex.prefix(12)), privacy: .public)")
                continue
            }
            targets.append((device, pushURL))
        }

        let logger = self.logger
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sendAPNsPush(payload, to: target.device, pushURL: target.pushURL)
                    } catch {
                        logger.error("[APNs] fan-out failed deviceKey=\(String(target.device.pubkeyHex.prefix(12)), privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Encrypt `payload` for one device and POST it to the relay `/push`
    /// endpoint. Throws on a missing token, unknown peer, or relay/APNs
    /// rejection so callers can log the specific failure.
    func sendAPNsPush(_ payload: NotificationPayload, to device: PairedDevice, pushURL: URL) async throws {
        guard let token = Self.apnsToken(for: device), !token.isEmpty else {
            throw MobilePushError.missingDeviceToken
        }
        let deviceClient = clientForDevice(device)
        guard let peer = await deviceClient?.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }

        let plaintext = AlertPlaintext(
            title: payload.title,
            body: payload.body,
            sessionID: payload.sessionID,
            projectID: payload.projectID,
            kind: payload.kind.rawValue
        )
        let encrypted = try APNsCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: peer
        )
        let encryptedAlertData = try JSONEncoder().encode(encrypted)
        let body = APNsPushRequest(
            provider: nil,
            deviceToken: token,
            encryptedAlert: encryptedAlertData.base64EncodedString(),
            category: payload.kind.rawValue,
            collapseID: Self.notificationCollapseID(for: payload, device: device),
            apnsEnvironment: Self.apnsEnvironmentForPush(device)
        )

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("[APNs] sending push kind=\(payload.kind.rawValue, privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) tokenPrefix=\(String(token.prefix(12)), privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePushError.relayRejected(status: -1, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobilePushError.relayRejected(
                status: http.statusCode,
                body: Self.responseBodyString(data)
            )
        }
        let pushResponse = try JSONDecoder().decode(APNsPushResponse.self, from: data)
        guard (200..<300).contains(pushResponse.statusCode) else {
            throw MobilePushError.apnsRejected(
                status: pushResponse.statusCode,
                reason: pushResponse.reason ?? "Unknown error"
            )
        }
    }

    func sendFCMPush(_ payload: NotificationPayload, to device: PairedDevice, pushURL: URL) async throws {
        guard let token = Self.pushToken(for: device), !token.isEmpty else {
            throw MobilePushError.missingDeviceToken
        }
        let deviceClient = clientForDevice(device)
        guard let peer = await deviceClient?.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }

        let plaintext = AlertPlaintext(
            title: payload.title,
            body: payload.body,
            sessionID: payload.sessionID,
            projectID: payload.projectID,
            kind: payload.kind.rawValue
        )
        let encrypted = try APNsCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: peer
        )
        let encryptedAlertData = try JSONEncoder().encode(encrypted)
        let body = PushRequest(
            provider: "fcm",
            deviceToken: token,
            encryptedAlert: encryptedAlertData.base64EncodedString(),
            category: payload.kind.rawValue,
            collapseID: Self.notificationCollapseID(for: payload, device: device),
            apnsEnvironment: nil
        )

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        logger.info("[FCM] sending push kind=\(payload.kind.rawValue, privacy: .public) deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) tokenPrefix=\(String(token.prefix(12)), privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePushError.relayRejected(status: -1, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobilePushError.relayRejected(
                status: http.statusCode,
                body: Self.responseBodyString(data)
            )
        }
        let pushResponse = try JSONDecoder().decode(PushResponse.self, from: data)
        guard (200..<300).contains(pushResponse.statusCode) else {
            throw MobilePushError.fcmRejected(
                status: pushResponse.statusCode,
                reason: pushResponse.reason ?? "Unknown error"
            )
        }
    }

    /// Send one APNs-backed test notification to a paired device.
    func sendTestNotification(to device: PairedDevice) async throws {
        if Self.pushProvider(for: device) == "fcm" {
            guard let deviceRelayURL = pushEndpointURL(for: device) else {
                throw MobilePushError.invalidRelayURL
            }
            let payload = NotificationPayload(
                kind: .generic,
                title: "RxCode test notification",
                body: "Notifications are working for \(device.displayName)."
            )
            try await sendFCMPush(payload, to: device, pushURL: deviceRelayURL)
            return
        }

        guard let token = Self.apnsToken(for: device), !token.isEmpty else {
            throw MobilePushError.missingDeviceToken
        }
        let deviceClient = clientForDevice(device)
        guard let peer = await deviceClient?.peer(forHex: device.pubkeyHex) else {
            throw MobilePushError.unknownPeer
        }
        guard let relayURLString = device.relayURL,
              let deviceRelayURL = URL(string: relayURLString),
              let pushURL = Self.pushEndpointURL(from: deviceRelayURL) else {
            throw MobilePushError.invalidRelayURL
        }

        logger.info("[APNs] sending test push deviceKey=\(String(device.pubkeyHex.prefix(12)), privacy: .public) tokenPrefix=\(String(token.prefix(12)), privacy: .public) environment=\(device.apnsEnvironment ?? "<nil>", privacy: .public) sender=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
        let plaintext = AlertPlaintext(
            title: "RxCode test notification",
            body: "Notifications are working for \(device.displayName).",
            kind: NotificationPayload.Kind.generic.rawValue
        )
        let encrypted = try APNsCrypto.seal(
            plaintext: plaintext,
            sender: identity.privateKey,
            recipient: peer
        )
        let encryptedAlertData = try JSONEncoder().encode(encrypted)
        let body = APNsPushRequest(
            provider: nil,
            deviceToken: token,
            encryptedAlert: encryptedAlertData.base64EncodedString(),
            category: "test_notification",
            collapseID: Self.testNotificationCollapseID(for: device),
            apnsEnvironment: Self.apnsEnvironmentForPush(device)
        )

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MobilePushError.relayRejected(status: -1, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MobilePushError.relayRejected(
                status: http.statusCode,
                body: Self.responseBodyString(data)
            )
        }

        let pushResponse = try JSONDecoder().decode(APNsPushResponse.self, from: data)
        guard (200..<300).contains(pushResponse.statusCode) else {
            throw MobilePushError.apnsRejected(
                status: pushResponse.statusCode,
                reason: pushResponse.reason ?? "Unknown error"
            )
        }
    }
}
