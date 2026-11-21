import AppKit
import RxAuthSwift
import RxCodeCore
import SwiftUI

/// Model details sit below the tags, with the assigned provider at the far edge.
struct TaskCardModelRow: View {
    @Environment(AppState.self) private var appState
    @State private var menuAnchor = NSView()

    let task: ProjectTask
    let board: TaskBoard
    let isUpdating: Bool
    let onSelect: (AgentModel?) -> Void
    let onEditEffort: () -> Void

    private var agent: TaskAgentConfig { task.agent }

    private var provider: AgentProvider { agent.provider ?? appState.taskModelSelection(for: task).provider }

    private var modelTitle: String {
        guard agent.isAssigned else { return String(localized: "Select Model") }
        if let model = agent.model, !model.isEmpty {
            return appState.modelDisplayLabel(model, provider: provider)
        }
        return provider.displayNameText
    }

    private var selectedModelId: String? {
        if provider == .acp, let parts = appState.acpSelectionParts(for: agent.model) {
            return "\(parts.clientId)::\(parts.model)"
        }
        return agent.model
    }

    private var providerLabel: String {
        guard provider == .acp,
              let clientId = appState.acpSelectionParts(for: agent.model)?.clientId,
              let client = appState.acpClients.first(where: { $0.id == clientId }) else {
            return provider.displayNameText
        }
        return client.displayName
    }

    var body: some View {
        let canEdit = board.canEditCard(assigneeIds: task.assigneeIds, userID: appState.rxAuth.user?.id)
        if agent.isAssigned || canEdit {
            ClaudeThemeDivider()
            HStack(spacing: 8) {
                if agent.isAssigned {
                    thinkingLevel(canEdit: canEdit)
                }
                if canEdit {
                    modelMenu
                } else {
                    footerLabel
                }
            }
        }
    }

    @ViewBuilder
    private func thinkingLevel(canEdit: Bool) -> some View {
        let selection = appState.taskModelSelection(for: task)
        let levels = appState.reasoningLevels(for: selection.provider, model: selection.model)
        let saved = agent.effort.flatMap { $0.isEmpty ? nil : $0 }
        if !levels.isEmpty || saved != nil {
            let title = saved.map { effort in
                levels.first { $0.id == effort }?.displayName ?? effortDisplayName(effort)
            } ?? appState.defaultEffortTitle(for: selection.provider, model: selection.model)
            let pill = TaskPill(text: title, icon: "brain", tint: saved == nil ? ClaudeTheme.textSecondary : ClaudeTheme.accent)
            Group {
                if canEdit && !levels.isEmpty {
                    Button(action: onEditEffort) { pill }
                        .buttonStyle(.plain)
                        .disabled(isUpdating)
                        .pointerCursorOnHover()
                } else {
                    pill
                }
            }
            .fixedSize()
            .help("Thinking level for the next task run")
            .accessibilityLabel("Thinking Level")
            .accessibilityValue(title)
            .accessibilityIdentifier("task-card-effort-\(task.id.uuidString)")
        }
    }

    private var modelMenu: some View {
        Button(action: showModelMenu) {
            footerLabel
        }
        .buttonStyle(.plain)
        .background(TaskModelMenuAnchor(view: menuAnchor).allowsHitTesting(false))
        .disabled(isUpdating)
        .pointerCursorOnHover()
        .help("Change task model")
        .accessibilityLabel(Text(modelTitle))
        .accessibilityIdentifier("task-card-model-\(task.id.uuidString)")
    }

    private func showModelMenu() {
        guard menuAnchor.window != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let actions = TaskModelMenuActions(onSelect: onSelect)
        menu.addItem(actions.item(String(localized: "Unassigned"), model: nil, isSelected: !agent.isAssigned))
        let currentModel = selectedModelId
        for section in appState.availableAgentModelSections() {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: section.title))
            for model in section.models {
                let isSelected = model.provider == provider && model.id == currentModel
                menu.addItem(actions.item(model.displayName, model: model, isSelected: isSelected))
            }
        }
        let bounds = menuAnchor.bounds
        let origin = NSPoint(x: bounds.minX, y: menuAnchor.isFlipped ? bounds.maxY : bounds.minY)
        // AppKit's menu targets are weak and must stay alive through tracking.
        withExtendedLifetime(actions) {
            _ = menu.popUp(positioning: nil, at: origin, in: menuAnchor)
        }
    }

    private var footerLabel: some View {
        HStack(spacing: 8) {
            Text(modelTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if agent.isAssigned {
                providerIcon
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(providerLabel)
            }
        }
        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
        .foregroundStyle(ClaudeTheme.textSecondary)
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var providerIcon: some View {
        switch provider {
        case .claudeCode:
            Image("ClaudeProvider")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        case .codex:
            Image("CodexProvider")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        case .acp:
            let clientId = appState.acpSelectionParts(for: agent.model)?.clientId
            let iconURL = appState.acpClients.first(where: { $0.id == clientId })?.iconURL
            ACPIconView(url: iconURL, size: 14)
        case .localAgent, .flowcy:
            Image(systemName: provider == .flowcy ? "cloud" : "desktopcomputer")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }
}

/// Gives the SwiftUI footer's native dropdown a position in the window.
private struct TaskModelMenuAnchor: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TaskModelMenuActions: NSObject {
    private let onSelect: (AgentModel?) -> Void

    init(onSelect: @escaping (AgentModel?) -> Void) {
        self.onSelect = onSelect
    }

    func item(_ title: String, model: AgentModel?, isSelected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectModel(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = model
        item.state = isSelected ? .on : .off
        return item
    }

    @objc private func selectModel(_ item: NSMenuItem) {
        guard item.state != .on else { return }
        onSelect(item.representedObject as? AgentModel)
    }
}
