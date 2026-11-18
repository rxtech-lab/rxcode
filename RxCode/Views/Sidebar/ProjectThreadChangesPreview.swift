import RxCodeCore
import SwiftUI

/// A thread's line totals across its recorded file edits.
nonisolated struct ThreadChangeTotals: Sendable, Equatable {
    let added: Int
    let removed: Int
}

/// The `+added −removed` readout a sidebar thread row shows while hovered.
struct ProjectThreadChangesPreview: View {
    let totals: ThreadChangeTotals

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(totals.added)")
                .foregroundStyle(ClaudeTheme.statusSuccess)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(totals.added)))
            Text("−\(totals.removed)")
                .foregroundStyle(ClaudeTheme.statusError)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(totals.removed)))
        }
        .font(.system(size: ClaudeTheme.size(11), weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(totals.added) lines added, \(totals.removed) lines removed"))
    }
}
