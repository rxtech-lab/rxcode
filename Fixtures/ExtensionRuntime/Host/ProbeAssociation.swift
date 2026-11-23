import Foundation

/// Explicit pairings for this experiment. The process and scene must separately
/// satisfy the pinned team and bundle requirement before a paired turn advances.
struct ProbeAssociation: Decodable {
    let service: String
    let sidebar: String
    let team: String

    static let all: [Self] = {
        guard let entries = Bundle.main.object(forInfoDictionaryKey: "ProbeAssociations"),
              let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0),
              let pairs = try? PropertyListDecoder().decode([Self].self, from: data) else { return [] }
        return pairs
    }()

    func requirement(for identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }
}
