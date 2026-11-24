import Contacts
import CryptoKit
import Foundation
import RxCodeCore
import RxCodeExtensionSDK

/// Serializes updates from multiple surfaces belonging to the same contributor.
actor ExtensionBrokerStorage {
    static let shared = ExtensionBrokerStorage()

    func value(identity: String, key: String, set newValue: JSONValue?) throws -> JSONValue {
        guard !key.isEmpty, key.utf8.count <= 256 else { throw ExtensionCallError.invalidRequest }
        let namespace = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = AppSupport.bundleScopedURL.appending(path: "ExtensionStorage")
        let url = root.appending(path: namespace + ".json")
        var values: [String: JSONValue]
        do { values = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { values = [:] }
        if let newValue {
            values[key] = newValue
            let encoded = try JSONEncoder().encode(values)
            guard encoded.count <= 1024 * 1024 else { throw ExtensionCallError.invalidRequest }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try encoded.write(to: url, options: .atomic)
        }
        return values[key] ?? .null
    }

    func contacts(named name: String, userInitiated: Bool) async throws -> [[String: String]] {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: break
        case .notDetermined:
            guard userInitiated else { throw ExtensionCallError.permissionPending }
            guard try await store.requestAccess(for: .contacts) else { throw ExtensionCallError.permissionDenied }
        default: throw ExtensionCallError.permissionDenied
        }
        try Task.checkCancellation()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 256 else { throw ExtensionCallError.invalidRequest }
        let query = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor,
                                                        CNContactFamilyNameKey as CNKeyDescriptor,
                                                        CNContactEmailAddressesKey as CNKeyDescriptor])
        query.predicate = CNContact.predicateForContacts(matchingName: name)
        var result: [[String: String]] = []
        try store.enumerateContacts(with: query) { contact, stop in
            result.append(["givenName": contact.givenName, "familyName": contact.familyName,
                           "email": contact.emailAddresses.first?.value as String? ?? ""])
            if result.count == 100 || Task.isCancelled { stop.pointee = true }
        }
        return result
    }
}
