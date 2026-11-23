import Foundation

public enum Probe {
    public static let major = 1
    public static let scene = "sidebar"
}

/// Private test protocol. A chunk acknowledgement controls when the producer may advance.
@objc(RXCProbeEvents) public protocol ProbeEvents: NSObjectProtocol {
    func chunk(_ streamID: String, sequence: Int, acknowledge: @escaping (Bool) -> Void)
    func finished(_ streamID: String)
}

@objc(RXCProbeService) public protocol ProbeService: NSObjectProtocol {
    func handshake(reply: @escaping (Int, String) -> Void)
    func start(_ streamID: String)
    func startListener(reply: @escaping (Int, String?) -> Void)
    func stopListener(reply: @escaping () -> Void)
}
