import SwiftUI

/// Edits assignment in a dedicated sheet; changes remain in the parent card draft until it is saved.
public struct CardAssigneePicker: View {
    @Binding private var ids: [String]
    @Binding private var profiles: [CardAssignee]
    private let members: [CardAssignee]
    @State private var isPresented = false

    public init(ids: Binding<[String]>, profiles: Binding<[CardAssignee]>, members: [CardAssignee]) {
        _ids = ids
        _profiles = profiles
        self.members = members
    }

    private var assigned: [CardAssignee] {
        ids.map { id in members.first { $0.id == id } ?? profiles.first { $0.id == id } ?? CardAssignee(userId: id) }
    }

    private var summary: String {
        let names = assigned.map(\.displayName)
        switch names.count {
        case 0: return String(localized: "Unassigned", bundle: .module)
        case 1, 2: return names.joined(separator: ", ")
        default: return String(localized: "\(names[0]) and \(names.count - 1) others", bundle: .module)
        }
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text("Assignees", bundle: .module)
                } icon: {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !assigned.isEmpty {
                    CardAssigneeAvatarStack(assignees: assigned)
                }
                Text(summary)
                    .foregroundStyle(assigned.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        // A bordered button draws its own box inside the form row.
        .buttonStyle(.plain)
        .accessibilityValue(summary)
        .accessibilityIdentifier("card-assignees-picker")
        .sheet(isPresented: $isPresented) {
            CardAssigneeSelectionSheet(ids: ids, profiles: profiles, members: members) { selected in
                ids = selected
                profiles = selected.map { id in
                    members.first { $0.id == id } ?? profiles.first { $0.id == id } ?? CardAssignee(userId: id)
                }
            }
        }
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: isPresented)
        #endif
    }
}

/// A member's photo, falling back to their initial when there is none.
private struct CardAssigneeAvatar: View {
    let assignee: CardAssignee
    let size: CGFloat

    var body: some View {
        AsyncImage(url: assignee.image.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle()
                .fill(.tint.opacity(0.2))
                .overlay {
                    Text(assignee.displayName.prefix(1).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.tint)
                }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Up to three overlapping avatars for the form row.
private struct CardAssigneeAvatarStack: View {
    let assignees: [CardAssignee]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(assignees.prefix(3)) { assignee in
                CardAssigneeAvatar(assignee: assignee, size: 20)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CardAssigneeSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String]
    @State private var search = ""
    let profiles: [CardAssignee]
    let members: [CardAssignee]
    let onSave: ([String]) -> Void

    init(ids: [String], profiles: [CardAssignee], members: [CardAssignee], onSave: @escaping ([String]) -> Void) {
        _selected = State(initialValue: ids)
        self.profiles = profiles
        self.members = members
        self.onSave = onSave
    }

    private var rows: [CardAssignee] {
        let missing = selected.filter { id in !members.contains { $0.id == id } }.map { id in
            profiles.first { $0.id == id } ?? CardAssignee(userId: id)
        }
        return (members + missing).filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                || ($0.email?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(search.isEmpty ? "No Project Members" : "No Matching Members", bundle: .module)
                        } icon: {
                            Image(systemName: "person.2")
                        }
                    } description: {
                        Text("Sign in and refresh the project to load its team members.", bundle: .module)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rows) { member in
                        Button {
                            if selected.contains(member.id) { selected.removeAll { $0 == member.id } }
                            else { selected.append(member.id) }
                        } label: {
                            HStack(spacing: 12) {
                                CardAssigneeAvatar(assignee: member, size: 32)
                                VStack(alignment: .leading) {
                                    Text(member.displayName)
                                    if let email = member.email { Text(email).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if selected.contains(member.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("card-assignee-\(member.id)")
                        .accessibilityAddTraits(selected.contains(member.id) ? [.isSelected] : [])
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .searchable(text: $search, prompt: Text("Find a project member", bundle: .module))
            .navigationTitle(Text("Assign People", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel", bundle: .module) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onSave(selected); dismiss() } label: { Text("Done", bundle: .module) }
                        .accessibilityIdentifier("card-assignees-done")
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 520)
        #else
        .sensoryFeedback(.selection, trigger: selected)
        #endif
    }
}
