import SwiftUI
import RxCodeCore

struct InspectorToolTabStrip: View {
    @Environment(WindowState.self) private var windowState

    let pane: InspectorToolLayout.Pane
    let isFocused: Bool
    let terminals: InspectorTerminalStore
    let actions: InspectorPaneTabActions<InspectorTabDrag>
    let onClose: (UUID) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(pane.tabs) { tab in
                            tabButton(tab).id(tab.id)
                        }
                        if !pane.tabs.isEmpty {
                            InspectorTabEndDropTarget { actions.move($0, nil) }
                                .frame(width: 24)
                        }
                    }
                    .frame(height: 30)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onChange(of: pane.selectedTabID, initial: true) { _, selected in
                    if let selected { reader.scrollTo(selected) }
                }
            }
            .frame(height: 30)

            addMenu
            terminalActions
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.5))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var terminalActions: some View {
        if let tab = pane.selectedTab, tab.tool == .terminal {
            let key = InspectorTerminalStore.Key(tabID: tab.id, sessionID: windowState.currentSessionId ?? windowState.newSessionKey)
            Menu {
                Button("Clear Terminal") { terminals.clearTerminal(in: key) }
                Button("Reset Terminal") { terminals.resetTerminal(in: key) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Terminal Actions")
            .accessibilityLabel("Terminal actions")
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(InspectorTab.allCases, id: \.self) { tool in
                Button { windowState.inspectorLayout.tools.add(tool, to: pane.id) } label: {
                    Label { Text(tool.title) } icon: { Image(systemName: tool.icon) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add Tool Tab")
        .accessibilityLabel("Add Tool Tab")
        .accessibilityIdentifier("inspector-add-tool-tab")
    }

    private func tabButton(_ tab: InspectorToolLayout.Tab) -> some View {
        InspectorTabButton(
            tab: tab,
            isSelected: pane.selectedTabID == tab.id,
            isFocused: isFocused,
            onSelect: { windowState.inspectorLayout.tools.select(tab.id) },
            onClose: { onClose(tab.id) }
        )
        .modifier(InspectorDraggableTab(
            item: InspectorTabDrag(id: tab.id, windowID: windowState.id),
            tabIDs: pane.tabs.map(\.id), actions: actions, onClose: { onClose(tab.id) }
        ))
    }
}

private struct InspectorTabButton: View {
    let tab: InspectorToolLayout.Tab
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    private var isActive: Bool { isSelected && isFocused }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.tool.icon)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(isActive ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                .frame(width: 14)
            Text(tab.tool.title)
                .font(.system(size: ClaudeTheme.size(12), weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
            WorkspaceTabCloseButton(isVisible: isHovered, action: onClose)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .workspaceTabChip(selected: isSelected, hovered: isHovered, emphasized: isFocused)
        .contentShape(.rect(cornerRadius: 7))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.tool.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Close Tab", onClose)
        .accessibilityIdentifier("inspector-tool-\(tab.tool.rawValue.lowercased())")
        .onHover { isHovered = $0 }
    }
}
