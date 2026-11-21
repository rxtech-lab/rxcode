import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tab chip styling

/// The shared look of inspector tab strips: browser tabs, tool tabs, and terminal tabs.
/// The selected tab is a raised card; others only show a soft fill on hover.
struct WorkspaceTabChipBackground: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    /// Selected tabs in an unfocused pane stay raised but drop their emphasis.
    var isEmphasized = true
    var cornerRadius: CGFloat = 7

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if isSelected {
                    shape.fill(ClaudeTheme.surfaceElevated.opacity(isEmphasized ? 1 : 0.6))
                        .shadow(color: .black.opacity(isEmphasized ? 0.22 : 0), radius: 1.5, y: 0.5)
                } else if isHovered {
                    shape.fill(ClaudeTheme.surfaceTertiary.opacity(0.55))
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(ClaudeTheme.borderSubtle.opacity(isEmphasized ? 0.9 : 0.5), lineWidth: 0.5)
                }
            }
    }
}

extension View {
    func workspaceTabChip(selected: Bool, hovered: Bool, emphasized: Bool = true, cornerRadius: CGFloat = 7) -> some View {
        modifier(WorkspaceTabChipBackground(isSelected: selected, isHovered: hovered,
                                            isEmphasized: emphasized, cornerRadius: cornerRadius))
    }
}

/// The shared look of second-level tabs (terminal sessions, run tasks, change lists):
/// a quiet label with an accent underline under the selection.
struct WorkspaceUnderlineTabBackground: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .frame(height: 30)
            .background(isHovered && !isSelected ? ClaudeTheme.surfaceTertiary.opacity(0.3) : .clear,
                        in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(ClaudeTheme.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .opacity(isSelected ? 1 : 0)
            }
            .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

extension View {
    func workspaceUnderlineTab(selected: Bool, hovered: Bool) -> some View {
        modifier(WorkspaceUnderlineTabBackground(isSelected: selected, isHovered: hovered))
    }
}

/// The trailing close button on a tab. It keeps its space when hidden so the tab width never jumps.
struct WorkspaceTabCloseButton: View {
    let isVisible: Bool
    var help: LocalizedStringKey = "Close Tab"
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: ClaudeTheme.size(8), weight: .bold))
                .foregroundStyle(isHovered ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
                .frame(width: 16, height: 16)
                .background(isHovered ? ClaudeTheme.surfaceTertiary : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityHidden(!isVisible)
    }
}

/// A borderless icon button sized for tab strip toolbars.
struct WorkspaceTabStripButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(isHovered ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(isHovered ? ClaudeTheme.surfaceTertiary.opacity(0.55) : .clear,
                            in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Live drag reordering

/// Payload prefix for tab drags that stay inside one strip. Plain text keeps the drag
/// local to RxCode without declaring another exported type.
enum WorkspaceTabDragPayload {
    static let prefix = "rxcode-tab:"

    static func provider(for id: UUID) -> NSItemProvider {
        NSItemProvider(object: (prefix + id.uuidString) as NSString)
    }
}

/// Reorders tabs while the pointer moves over them, so neighbours slide out of the way.
/// External URL drops (links, addresses dragged from other apps) go to `onExternalURLs`.
struct WorkspaceTabReorderDropDelegate: DropDelegate {
    /// The tab under the pointer, or nil for the empty area after the last tab.
    let targetID: UUID?
    @Binding var draggingID: UUID?
    let move: (_ dragged: UUID, _ target: UUID?) -> Void
    var onExternalURLs: (([URL]) -> Void)?

    private func isInternal(_ info: DropInfo) -> Bool {
        draggingID != nil && !info.hasItemsConforming(to: [.url, .fileURL])
    }

    func validateDrop(info: DropInfo) -> Bool {
        isInternal(info) || (onExternalURLs != nil && info.hasItemsConforming(to: [.url]))
    }

    func dropEntered(info: DropInfo) {
        guard isInternal(info), let draggingID, draggingID != targetID else { return }
        withAnimation(.smooth(duration: 0.2)) { move(draggingID, targetID) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isInternal(info) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        if isInternal(info) {
            draggingID = nil
            return true
        }
        guard let onExternalURLs else { return false }
        let providers = info.itemProviders(for: [.url])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in onExternalURLs([url]) }
            }
        }
        return true
    }
}

extension View {
    /// Makes a tab draggable within its strip and a drop target for reordering.
    func workspaceReorderableTab(
        id: UUID,
        draggingID: Binding<UUID?>,
        move: @escaping (UUID, UUID?) -> Void,
        onExternalURLs: (([URL]) -> Void)? = nil
    ) -> some View {
        self
            .opacity(draggingID.wrappedValue == id ? 0.35 : 1)
            .onDrag {
                draggingID.wrappedValue = id
                return WorkspaceTabDragPayload.provider(for: id)
            }
            .onDrop(of: [.plainText, .url], delegate: WorkspaceTabReorderDropDelegate(
                targetID: id, draggingID: draggingID, move: move, onExternalURLs: onExternalURLs
            ))
    }

    /// The strip's empty area: dropping here moves a tab to the end or opens dropped URLs.
    func workspaceTabStripDropArea(
        draggingID: Binding<UUID?>,
        move: @escaping (UUID, UUID?) -> Void,
        onExternalURLs: (([URL]) -> Void)? = nil
    ) -> some View {
        onDrop(of: [.plainText, .url], delegate: WorkspaceTabReorderDropDelegate(
            targetID: nil, draggingID: draggingID, move: move, onExternalURLs: onExternalURLs
        ))
    }
}

extension Array where Element: Identifiable, Element.ID == UUID {
    /// Moves `dragged` into the slot of `target`, or to the end when `target` is nil.
    /// Returns the dragged element's previous index when anything moved.
    @discardableResult
    mutating func moveTab(_ dragged: UUID, to target: UUID?) -> Int? {
        guard let from = firstIndex(where: { $0.id == dragged }) else { return nil }
        if let target {
            guard target != dragged, let to = firstIndex(where: { $0.id == target }) else { return nil }
            move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        } else {
            guard from != count - 1 else { return nil }
            append(remove(at: from))
        }
        return from
    }
}

// MARK: - Fixed tab pickers

/// A leading-aligned row of chip tabs for a fixed set of choices, matching the Tools and browser strips.
struct WorkspaceChipTabPicker<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    var accessibilityPrefix: String?
    @ViewBuilder let label: (Value, Bool) -> Label

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    WorkspaceChipTab(isSelected: option == selection, select: { selection = option }) {
                        label(option, option == selection)
                    }
                    .accessibilityIdentifier(accessibilityPrefix.map { "\($0)-\(String(describing: option))" } ?? "")
                }
            }
            .frame(height: 30)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .animation(.smooth(duration: 0.18), value: selection)
    }
}

private struct WorkspaceChipTab<Label: View>: View {
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        label()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .workspaceTabChip(selected: isSelected, hovered: isHovered)
            .contentShape(.rect(cornerRadius: 7))
            .onTapGesture(perform: select)
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The standard chip label: icon plus title, accent icon when selected.
struct WorkspaceChipTabLabel: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: ClaudeTheme.size(12), weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// A second-level tab row: quiet labels with an accent underline under the selection.
struct WorkspaceUnderlineTabPicker<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    @ViewBuilder let label: (Value, Bool) -> Label
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                WorkspaceUnderlineTab(isSelected: option == selection, namespace: underline,
                                      select: { selection = option }) {
                    label(option, option == selection)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: selection)
    }
}

private struct WorkspaceUnderlineTab<Label: View>: View {
    let isSelected: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        label()
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isHovered && !isSelected ? ClaudeTheme.surfaceTertiary.opacity(0.3) : .clear,
                        in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(ClaudeTheme.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                        .matchedGeometryEffect(id: "underline", in: namespace)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Title plus an optional count badge for underline tabs.
struct WorkspaceUnderlineTabLabel: View {
    let title: LocalizedStringResource
    var count: Int?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: ClaudeTheme.size(12), weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
            if let count {
                Text(count, format: .number)
                    .font(.system(size: ClaudeTheme.size(10), weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 16)
                    .background((isSelected ? ClaudeTheme.accent : ClaudeTheme.textTertiary).opacity(0.15), in: .capsule)
            }
        }
        .fixedSize()
    }
}
