import SwiftUI
import RxCodeCore

/// The inspector destinations assigned to one pane.
struct InspectorDestinationBar: View {
    @Environment(WindowState.self) private var windowState
    let pane: InspectorDestinationLayout.Pane
    let actions: InspectorPaneTabActions<InspectorDestinationDrag>

    var body: some View {
        GeometryReader { geometry in
            let fullCount = CGFloat(InspectorMode.allCases.count)
            let spacing: CGFloat = 3
            let tabWidth = max(96, (geometry.size.width - spacing * (fullCount - 1)) / fullCount)

            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(pane.tabs) { mode in
                            destination(mode, minimumWidth: tabWidth)
                                .modifier(InspectorDraggableTab(
                                    item: InspectorDestinationDrag(id: mode, windowID: windowState.id),
                                    tabIDs: pane.tabs, actions: actions
                                ))
                                .id(mode)
                        }
                        if pane.tabs.count < InspectorMode.allCases.count {
                            InspectorTabEndDropTarget { actions.move($0, nil) }
                                .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: geometry.size.width, minHeight: 28, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onChange(of: pane.selectedTabID, initial: true) { _, mode in
                    if let mode { reader.scrollTo(mode) }
                }
            }
        }
        .frame(height: 28)
    }

    private func destination(_ mode: InspectorMode, minimumWidth: CGFloat) -> some View {
        let selected = pane.selectedTab == mode
        let focused = windowState.inspectorLayout.destinations.focusedPaneID == pane.id
        return Button { windowState.inspectorMode = mode } label: {
            Label {
                Text(mode.title).lineLimit(1)
            } icon: {
                Image(systemName: symbol(for: mode))
                    .symbolRenderingMode(.monochrome)
            }
            .font(.system(size: ClaudeTheme.size(12), weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(minWidth: minimumWidth, minHeight: 28)
            .background(selected ? ClaudeTheme.accentSubtle.opacity(focused ? 1 : 0.6) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("inspector-destination-\(mode.rawValue.lowercased())")
    }

    private func symbol(for mode: InspectorMode) -> String {
        switch mode {
        case .changes: "arrow.triangle.branch"
        case .inspector: "terminal"
        case .preview: "rectangle.on.rectangle"
        case .browser: "globe"
        }
    }
}

// MARK: - HeaderIconButton

struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ClaudeTheme.size(11), weight: .semibold))
                .foregroundStyle(isHovered ? ClaudeTheme.textPrimary : ClaudeTheme.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    isHovered ? ClaudeTheme.surfaceSecondary : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Empty State Helper

struct InspectorEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.badge.plus")
                .font(.system(size: ClaudeTheme.size(32)))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text(title)
                .font(.system(size: ClaudeTheme.size(14), weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text(message)
                .font(.system(size: ClaudeTheme.size(12)))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
