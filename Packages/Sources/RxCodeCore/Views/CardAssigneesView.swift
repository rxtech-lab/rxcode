import SwiftUI

/// Card avatars open a small profile popover without entering the card editor.
public struct CardAssigneesView: View {
    private let profiles: [CardAssignee]
    @State private var selected: CardAssignee?

    public init(ids: [String], profiles: [CardAssignee]) {
        self.profiles = ids.map { id in profiles.first { $0.userId == id } ?? CardAssignee(userId: id) }
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(profiles) { profile in
                Button { selected = profile } label: {
                    AsyncImage(url: profile.image.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Text(String(profile.displayName.prefix(1)).uppercased())
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.quaternary)
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44)
                    #endif
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show profile for \(profile.displayName)")
                .popover(isPresented: Binding(get: { selected?.id == profile.id }, set: { if !$0 { selected = nil } })) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.displayName).font(.headline)
                        if let email = profile.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    .padding().frame(minWidth: 220, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: selected?.id)
        #endif
    }
}
