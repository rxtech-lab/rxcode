import RxCodeCore

/// Stable action prefixes shared by the settings list and menu visibility filter.
/// Settings always lists every action, even when its runtime condition is false.
struct BuiltInContextMenuAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let surfaces: [CustomMenuItemRecord.Surface]

    func matches(_ item: MenuItem) -> Bool {
        item.id.hasPrefix(id + ".")
    }

    static let all: [Self] = [
        .init(id: "builtin.actionsMenu.project.codeReview", title: "Code Review for Current Branch", systemImage: "checklist", surfaces: [.project, .briefing]),
        .init(id: "builtin.actionsMenu.project.commitAll", title: "Commit All Changes", systemImage: "checkmark.circle", surfaces: [.project, .briefing]),
        .init(id: "builtin.actionsMenu.project.createPR", title: "Create Pull Request", systemImage: "arrow.triangle.pull", surfaces: [.project, .briefing]),
        .init(id: "builtin.actionsMenu.project.fixCI", title: "Fix Failing CI", systemImage: "wrench.and.screwdriver", surfaces: [.project, .briefing]),
        .init(id: "builtin.actionsMenu.thread.codeReview", title: "Code Review for this thread", systemImage: "checklist", surfaces: [.thread]),
        .init(id: "builtin.actionsMenu.thread.commitFiles", title: "Commit Files", systemImage: "checkmark.circle", surfaces: [.thread]),
        .init(id: "builtin.actionsMenu.thread.stopCodeReview", title: "Stop Code Review", systemImage: "stop.circle", surfaces: [.thread]),
        .init(id: "builtin.autopilot.download", title: "Download Secret", systemImage: "key.fill", surfaces: [.project, .thread, .briefing]),
        .init(id: "builtin.autopilot.setup", title: "Set Up Secrets", systemImage: "key.fill", surfaces: [.project, .thread, .briefing]),
        .init(id: "builtin.docs.setup", title: "Set Up Docs", systemImage: "books.vertical.fill", surfaces: [.project, .thread, .briefing]),
        .init(id: "builtin.release.create", title: "Create Release", systemImage: "tag.fill", surfaces: [.project, .thread, .briefing]),
        .init(id: "builtin.release.setup", title: "Set Up Release Workflow", systemImage: "tag.fill", surfaces: [.project, .thread, .briefing]),
        .init(id: "builtin.ciupdate.setup", title: "Set Up CI Update", systemImage: "arrow.triangle.2.circlepath", surfaces: [.project, .thread, .briefing])
    ]

    static func visibleItems(_ items: [MenuItem], hiddenIDs: Set<String>) -> [MenuItem] {
        let hidden = all.filter { hiddenIDs.contains($0.id) }
        return items.filter { item in !hidden.contains { $0.matches(item) } }
    }
}
