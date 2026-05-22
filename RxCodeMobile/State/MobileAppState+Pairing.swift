import Foundation
import Combine
import CryptoKit
import RxCodeCore
import RxCodeChatKit
import RxCodeSync
import SwiftUI
import UIKit
import os.log
extension MobileAppState {
    func pair(with token: PairingToken, displayName: String) async {
        guard !token.isExpired,
              let desktopKey = token.desktopPublicKey else {
            failPairing("Invalid or expired pairing code.")
            return
        }
        pairingStatus = .inProgress
        let desktopHex = token.desktopPubkeyHex
        logger.info("pairing with relayURL=\(token.relayURL, privacy: .public)")
        // Persist the relay URL we just learned from the QR.
        if let url = URL(string: token.relayURL) {
            await updateRelayForPairingIfNeeded(url)
        } else {
            logger.error("pairing token has invalid relayURL=\(token.relayURL, privacy: .public)")
        }
        if !clientStarted {
            await startClient()
        }
        try? await client.addPeer(desktopHex)
        guard await waitForRelayConnection() else {
            logger.error("pairing relay connection timed out relay=\(self.relayURL.absoluteString, privacy: .public)")
            failPairing("Couldn't connect to the relay from the QR code. Check the relay address and try again.")
            return
        }
        let req = PairRequestPayload(
            mobilePubkeyHex: identity.publicKeyHex,
            displayName: displayName,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            apnsEnvironment: Self.currentAPNsEnvironment
        )
        do {
            logger.info("sending pair request via relay=\(self.relayURL.absoluteString, privacy: .public)")
            try await client.send(.pairRequest(req), toHex: desktopHex)
        } catch {
            logger.error("pair request send failed: \(error.localizedDescription, privacy: .public)")
            failPairing("Couldn't reach the relay. Check your network and try again.")
            return
        }
        _ = desktopKey  // silence unused
        startPairingTimeout()
    }

    func pair(from url: URL, displayName: String) async {
        do {
            let token = try PairingToken.parse(url.absoluteString)
            await pair(with: token, displayName: displayName)
        } catch {
            logger.error("pairing deeplink parse failed: \(error.localizedDescription, privacy: .public)")
            failPairing("Unrecognized pairing link. Generate a new QR code on your Mac.")
        }
    }

    func updateRelayForPairingIfNeeded(_ url: URL) async {
        UserDefaults.standard.set(url.absoluteString, forKey: "mobileSync.relayURL")
        guard url != relayURL else {
            logger.info("pairing relay already configured as \(url.absoluteString, privacy: .public)")
            return
        }

        logger.info("switching pairing relay to \(url.absoluteString, privacy: .public)")
        let oldClient = client
        eventTask?.cancel()
        eventTask = nil
        client = SyncClient(identity: identity, relayURL: url)
        relayURL = url
        connectionState = .disconnected
        await oldClient.stop()
        await startClient()
    }

    func waitForRelayConnection(timeoutSeconds: Double = 8) async -> Bool {
        logger.info("waiting for relay connection state=\(String(describing: self.connectionState), privacy: .public) relay=\(self.relayURL.absoluteString, privacy: .public)")
        if connectionState == .connected { return true }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if connectionState == .connected { return true }
        }
        return false
    }

    func cancelPairing() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingStatus = .idle
    }

    func dismissPairingError() {
        if case .failed = pairingStatus { pairingStatus = .idle }
    }

    func startPairingTimeout() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            let seconds = Self.pairingTimeoutSeconds
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.pairingStatus == .inProgress else { return }
                self.failPairing(
                    "Your Mac didn't respond. Make sure RxCode is open and connected, then try again."
                )
            }
        }
    }
}
