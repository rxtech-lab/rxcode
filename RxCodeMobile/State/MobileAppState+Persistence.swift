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
    func loadPairedDesktops() {
        let defaults = UserDefaults.standard
        let savedMobilePubkey = defaults.string(forKey: Self.mobilePubkeyKey)
        if let savedMobilePubkey,
           !savedMobilePubkey.isEmpty,
           savedMobilePubkey != identity.publicKeyHex {
            logger.warning("[Pairing] clearing stale saved desktop pairing savedMobileKey=\(String(savedMobilePubkey.prefix(12)), privacy: .public) currentMobileKey=\(String(self.identity.publicKeyHex.prefix(12)), privacy: .public)")
            pairedDesktops = []
            setActiveDesktop(pubkeyHex: nil)
            savePairedDesktops()
            return
        }

        if let data = defaults.data(forKey: Self.pairedDesktopsKey),
           let decoded = try? JSONDecoder().decode([PairedDesktop].self, from: data) {
            pairedDesktops = Self.deduplicate(decoded)
        } else {
            let legacyPubkey = defaults.string(forKey: Self.legacyDesktopPubkeyKey) ?? ""
            let legacyName = defaults.string(forKey: Self.legacyDesktopNameKey) ?? ""
            if !legacyPubkey.isEmpty {
                pairedDesktops = [
                    PairedDesktop(
                        pubkeyHex: legacyPubkey,
                        displayName: legacyName,
                        pairedAt: .now,
                        lastSeen: nil
                    )
                ]
            }
        }

        let preferred = defaults.string(forKey: Self.activeDesktopPubkeyKey)
            ?? defaults.string(forKey: Self.legacyDesktopPubkeyKey)
        setActiveDesktop(pubkeyHex: preferred)
        if !pairedDesktops.isEmpty {
            savePairedDesktops()
        }
    }

    func savePairedDesktops() {
        let defaults = UserDefaults.standard
        if pairedDesktops.isEmpty {
            defaults.removeObject(forKey: Self.pairedDesktopsKey)
            defaults.removeObject(forKey: Self.activeDesktopPubkeyKey)
            defaults.removeObject(forKey: Self.legacyDesktopPubkeyKey)
            defaults.removeObject(forKey: Self.legacyDesktopNameKey)
            defaults.removeObject(forKey: Self.mobilePubkeyKey)
        } else {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(pairedDesktops) {
                defaults.set(data, forKey: Self.pairedDesktopsKey)
            }
            defaults.set(pairedDesktopPubkey, forKey: Self.activeDesktopPubkeyKey)
            defaults.set(pairedDesktopPubkey, forKey: Self.legacyDesktopPubkeyKey)
            defaults.set(pairedDesktopName, forKey: Self.legacyDesktopNameKey)
            defaults.set(identity.publicKeyHex, forKey: Self.mobilePubkeyKey)
        }
    }

    func setActiveDesktop(pubkeyHex: String?) {
        let resolved = pubkeyHex.flatMap { requested in
            pairedDesktops.first { $0.pubkeyHex == requested }
        } ?? pairedDesktops.first

        pairedDesktopPubkey = resolved?.pubkeyHex ?? ""
        pairedDesktopName = resolved?.displayName ?? ""
        isPaired = resolved != nil
    }

    func upsertPairedDesktop(_ desktop: PairedDesktop) {
        if let index = pairedDesktops.firstIndex(where: { $0.pubkeyHex == desktop.pubkeyHex }) {
            let existing = pairedDesktops[index]
            pairedDesktops[index] = PairedDesktop(
                pubkeyHex: desktop.pubkeyHex,
                displayName: desktop.displayName,
                pairedAt: existing.pairedAt,
                lastSeen: desktop.lastSeen ?? existing.lastSeen
            )
        } else {
            pairedDesktops.append(desktop)
        }
    }

    func acceptsActiveDesktopPayload(from pubkeyHex: String, type: String) -> Bool {
        guard pubkeyHex == pairedDesktopPubkey else {
            logger.info("[Pairing] ignoring \(type, privacy: .public) from inactive desktopKey=\(String(pubkeyHex.prefix(12)), privacy: .public)")
            return false
        }
        return true
    }

    func removePairedDesktopAfterRemoteUnpair(_ desktop: PairedDesktop) async {
        let wasActive = desktop.pubkeyHex == pairedDesktopPubkey
        pairedDesktops.removeAll { $0.pubkeyHex == desktop.pubkeyHex }
        await client.removePeer(desktop.pubkeyHex)
        if wasActive {
            clearDesktopMirror()
            setActiveDesktop(pubkeyHex: pairedDesktops.first?.pubkeyHex)
        } else {
            setActiveDesktop(pubkeyHex: pairedDesktopPubkey)
        }
        savePairedDesktops()
        if wasActive, isPaired {
            await requestSnapshot()
            await reportAPNsTokenIfPending()
        }
    }

    static func deduplicate(_ desktops: [PairedDesktop]) -> [PairedDesktop] {
        var seen: Set<String> = []
        var result: [PairedDesktop] = []
        for desktop in desktops {
            guard !desktop.pubkeyHex.isEmpty, !seen.contains(desktop.pubkeyHex) else { continue }
            seen.insert(desktop.pubkeyHex)
            result.append(desktop)
        }
        return result
    }
}
