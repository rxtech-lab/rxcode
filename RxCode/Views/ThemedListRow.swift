import AppKit
import RxCodeCore
import SwiftUI

extension View {
    func themedListRow<Tag: Hashable>(_ tag: Tag, selection: Tag?) -> some View {
        themedListRow(tag, selected: selection == tag)
    }

    /// Keeps the List's native selection and keyboard handling while drawing the theme's selection color.
    func themedListRow<Tag: Hashable>(_ tag: Tag, selected: Bool) -> some View {
        modifier(ThemedListRow(selected: selected)).tag(tag)
    }
}

private struct ThemedListRow: ViewModifier {
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let emphasized = selected && isFocused && appearsActive
        let accent = ClaudeTheme.accent
        let shape = RoundedRectangle(cornerRadius: 6)
        return content
            .foregroundStyle(ClaudeTheme.textPrimary, ClaudeTheme.textSecondary, ClaudeTheme.textTertiary)
            .environment(\.themeSelectionBackground, emphasized ? accent : nil)
            .environment(\.backgroundProminence, .standard)
            .background {
                if selected { NativeRowHighlight().allowsHitTesting(false).accessibilityHidden(true) }
            }
            .listItemTint(.fixed(emphasized ? ClaudeTheme.foreground(on: accent) : accent))
            .listRowBackground(
                selected ? shape.fill(emphasized ? accent : ClaudeTheme.sidebarItemSelected)
                    .background(ClaudeTheme.sidebarBackground, in: shape) : nil
            )
    }
}

/// AppKit draws its opaque selection over a SwiftUI list row background.
/// Suppress that drawing only for the lifetime of this row's themed highlight.
private struct NativeRowHighlight: NSViewRepresentable {
    final class Anchor: NSView {
        private weak var row: NSTableRowView?
        private var originalStyle: NSTableView.SelectionHighlightStyle = .regular

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRow()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateRow()
        }

        func updateRow() {
            var ancestor = superview
            while ancestor != nil && !(ancestor is NSTableRowView) { ancestor = ancestor?.superview }
            let current = ancestor as? NSTableRowView
            if current !== row {
                restore()
                row = current
                originalStyle = current?.selectionHighlightStyle ?? .regular
            }
            if let row, row.selectionHighlightStyle != .none { row.selectionHighlightStyle = .none }
        }

        func restore() {
            if let row, row.selectionHighlightStyle == .none { row.selectionHighlightStyle = originalStyle }
            row = nil
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.updateRow() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.restore() }
}
