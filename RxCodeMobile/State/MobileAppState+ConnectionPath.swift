import Foundation
import RxCodeSync

/// How the phone currently reaches the active Mac, for the connection badge.
enum MobileConnectionRoute: Equatable {
    /// Peer-to-peer over the local network.
    case lan(rttMillis: Int?)
    /// Peer-to-peer over the internet through a mapped router port.
    case directInternet(rttMillis: Int?)
    /// Through the relay server.
    case relay(host: String?)
    case connecting
    case offline

    var title: String {
        switch self {
        case .lan: String(localized: "LAN")
        case .directInternet: String(localized: "Direct")
        case .relay: String(localized: "Relay")
        case .connecting: String(localized: "Connecting")
        case .offline: String(localized: "Offline")
        }
    }

    var detail: String {
        switch self {
        case .lan(let rtt):
            Self.withRTT(String(localized: "Connected directly over your local network."), rtt)
        case .directInternet(let rtt):
            Self.withRTT(String(localized: "Connected directly over the internet."), rtt)
        case .relay(let host):
            if let host {
                String(localized: "Connected through the relay server \(host). Messages stay end-to-end encrypted.")
            } else {
                String(localized: "Connected through the relay server. Messages stay end-to-end encrypted.")
            }
        case .connecting:
            String(localized: "Connecting to your Mac…")
        case .offline:
            String(localized: "Not connected to your Mac.")
        }
    }

    var systemImage: String {
        switch self {
        case .lan: "wifi"
        case .directInternet: "point.3.connected.trianglepath.dotted"
        case .relay: "cloud"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        }
    }

    private static func withRTT(_ text: String, _ rtt: Int?) -> String {
        guard let rtt else { return text }
        return text + " " + String(localized: "Round trip \(rtt) ms.")
    }
}

extension MobileAppState {
    /// The route to the active paired Mac. A direct link carries traffic even
    /// while the relay socket reconnects, so it wins over the relay state.
    var activeConnectionRoute: MobileConnectionRoute {
        let path = activePathByDesktop[pairedDesktopPubkey] ?? .relay
        let rtt = directRTTByDesktop[pairedDesktopPubkey] ?? nil
        switch path {
        case .directLAN: return .lan(rttMillis: rtt)
        case .directWAN: return .directInternet(rttMillis: rtt)
        case .relay: break
        }
        switch connectionState {
        case .connected: return .relay(host: relayURL.host)
        case .connecting, .reconnecting: return .connecting
        case .disconnected: return relaySuspendedForBackground ? .connecting : .offline
        }
    }

    /// Forget every direct-path state. The sync client tears its direct links
    /// down on `stop()` without emitting path changes, so callers that stop or
    /// replace the client reset the badge here.
    func resetConnectionPaths() {
        if !activePathByDesktop.isEmpty { activePathByDesktop = [:] }
        if !directRTTByDesktop.isEmpty { directRTTByDesktop = [:] }
    }
}
