import Foundation

/// Retains the highest authenticated sequence across catalog refreshes and app upgrades.
/// A bundled baseline and a network response must both pass the same signature and sequence checks.
public actor ExtensionRevocationStore {
    private struct SignedDocument: Codable {
        let rawPayload: Data
        let signature: String
    }

    private let file: URL
    private let key: Data
    public private(set) var current: ExtensionRevocations?
    public private(set) var lastRefreshed: Date?

    public init(file: URL, publicKey: Data) throws {
        self.file = file
        self.key = publicKey
        do {
            let stored = try JSONDecoder().decode(SignedDocument.self, from: Data(contentsOf: file))
            self.current = try ExtensionRevocations.verify(rawPayload: stored.rawPayload,
                                                          signature: stored.signature, publicKey: publicKey)
            self.lastRefreshed = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            self.current = nil
        }
    }

    #if DEBUG
    /// Early previews kept their authenticated test policy at the path now reserved for production.
    public func migrateSignedBaseline(from legacyFile: URL) throws {
        let raw: Data
        do { raw = try Data(contentsOf: legacyFile) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        let old = try JSONDecoder().decode(SignedDocument.self, from: raw)
        do { try loadBaseline(rawPayload: old.rawPayload, signature: old.signature) }
        catch ExtensionVerificationError.badSignature { return }
        // Keep a production record if another process has replaced the old file.
        if try Data(contentsOf: legacyFile) == raw {
            try FileManager.default.removeItem(at: legacyFile)
        }
    }
    #endif

    @discardableResult
    public func accept(rawPayload: Data, signature: String) throws -> ExtensionRevocations {
        let document = try ExtensionRevocations.verify(rawPayload: rawPayload, signature: signature,
                                                      publicKey: key, newerThan: current?.sequence ?? 0)
        let bytes = try JSONEncoder().encode(SignedDocument(rawPayload: rawPayload, signature: signature))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        current = document
        lastRefreshed = Date()
        return document
    }

    /// A release can ship a baseline that predates the user's most recently accepted update.
    public func loadBaseline(rawPayload: Data, signature: String) throws {
        do { try accept(rawPayload: rawPayload, signature: signature) }
        catch ExtensionVerificationError.staleSequence { return }
    }

    /// Returns a newly accepted policy so callers can invalidate running sessions immediately.
    public func refresh(bytes: Data, response: HTTPURLResponse) throws -> ExtensionRevocations? {
        if response.statusCode == 404 {
            lastRefreshed = Date()
            return nil
        }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard let signature = response.value(forHTTPHeaderField: "X-RxCode-Signature") else {
            throw ExtensionVerificationError.badSignature
        }
        do { return try accept(rawPayload: bytes, signature: signature) }
        catch ExtensionVerificationError.staleSequence {
            // Receiving the already accepted baseline on a routine refresh is expected.
            let candidate = try ExtensionRevocations.verify(rawPayload: bytes, signature: signature, publicKey: key)
            if candidate == current {
                lastRefreshed = Date()
                return nil
            }
            throw ExtensionVerificationError.staleSequence
        }
    }
}
