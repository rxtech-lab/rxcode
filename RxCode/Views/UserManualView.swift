import RxCodeChatKit
import RxCodeCore
import SwiftUI

struct UserManualView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMenu: UserManualMenu? = .overview

    private let documents: [UserManualMenu: BundledMarkdownDocument]

    init() {
        self.documents = Dictionary(uniqueKeysWithValues: UserManualMenu.allCases.map { menu in
            (
                menu,
                BundledMarkdownDocument.load(
                    baseName: menu.resourceBaseName,
                    fallbackTitle: menu.fallbackTitle
                )
            )
        })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 280)
        } detail: {
            detailView
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: ClaudeTheme.size(12), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(12)
        }
        .frame(width: 900, height: 680)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(UserManualMenu.allCases) { menu in
                    Button {
                        selectedMenu = menu
                    } label: {
                        UserManualSidebarRow(
                            title: documents[menu]?.titleText ?? menu.fallbackTitle,
                            icon: menu.icon,
                            isSelected: selectedMenu == menu
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ClaudeTheme.sidebarBackground)
        .navigationTitle("User Guide")
    }

    private var detailView: some View {
        let document = documents[selectedMenu ?? .overview] ?? .missing(title: UserManualMenu.overview.fallbackTitle)

        return ScrollView {
            MarkdownContentView(text: document.content)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(ClaudeTheme.background)
        .navigationTitle(document.titleText)
    }
}

private struct UserManualSidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: ClaudeTheme.size(14), weight: .medium))
                .frame(width: 22)

            Text(title)
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(ClaudeTheme.surfaceSecondary)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum UserManualMenu: String, CaseIterable, Identifiable {
    case overview
    case projects
    case chat
    case commands
    case permissions
    case settings
    case integrations
    case worktrees

    var id: String { rawValue }

    var resourceBaseName: String {
        "user_manual_\(rawValue)"
    }

    var fallbackTitle: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Projects and Sidebar"
        case .chat: "Chat and Attachments"
        case .commands: "Commands and Shortcuts"
        case .permissions: "Permissions and Inspector"
        case .settings: "Integrations and Settings"
        case .integrations: "MCP and ACP Clients"
        case .worktrees: "Git Worktrees"
        }
    }

    var icon: String {
        switch self {
        case .overview: "sparkle"
        case .projects: "sidebar.left"
        case .chat: "bubble.left.and.bubble.right"
        case .commands: "terminal.fill"
        case .permissions: "checkmark.shield"
        case .settings: "gearshape"
        case .integrations: "puzzlepiece.extension"
        case .worktrees: "arrow.triangle.branch"
        }
    }
}

private struct BundledMarkdownDocument {
    let titleText: String
    let content: String

    static func load(baseName: String, fallbackTitle: String, bundle: Bundle = .main) -> Self {
        let candidates = localizedResourceNames(for: baseName)

        for name in candidates {
            if let content = readMarkdown(named: name, bundle: bundle) {
                return Self(titleText: title(in: content) ?? fallbackTitle, content: content)
            }
        }

        return missing(title: fallbackTitle)
    }

    static func missing(title: String) -> Self {
        Self(
            titleText: title,
            content: "# \(title)\n\nThe bundled user guide section could not be loaded."
        )
    }

    private static func title(in content: String) -> String? {
        content
            .split(whereSeparator: \.isNewline)
            .lazy
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("# ") else { return nil }
                let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
            .first
    }

    private static func localizedResourceNames(for baseName: String) -> [String] {
        var names: [String] = []

        for identifier in Locale.preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "-", with: "_")
            let locale = Locale(identifier: identifier)
            let languageCode = locale.language.languageCode?.identifier
            let scriptCode = locale.language.script?.identifier
            let regionCode = locale.region?.identifier

            appendUnique("\(baseName)_\(normalized)", to: &names)

            if languageCode == "zh" {
                if regionCode == "HK" || regionCode == "MO" || regionCode == "TW" || scriptCode == "Hant" {
                    appendUnique("\(baseName)_zh_HK", to: &names)
                } else {
                    appendUnique("\(baseName)_zh_CN", to: &names)
                }
            } else if let languageCode {
                appendUnique("\(baseName)_\(languageCode)", to: &names)
            }
        }

        appendUnique(baseName, to: &names)
        return names
    }

    private static func readMarkdown(named name: String, bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return content
    }

    private static func appendUnique(_ name: String, to names: inout [String]) {
        guard !names.contains(name) else { return }
        names.append(name)
    }
}

#Preview {
    UserManualView()
}
