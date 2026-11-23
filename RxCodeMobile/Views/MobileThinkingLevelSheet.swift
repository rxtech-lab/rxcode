import RxCodeCore
import SwiftUI

struct MobileThinkingLevelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let levels: [ReasoningLevel]
    let selected: String?
    let defaultTitle: String
    let onSelect: (String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                row(defaultTitle, id: nil)
                ForEach(levels) { level in
                    row(level.displayName, id: level.id, detail: level.levelDescription)
                }
            }
            .navigationTitle("Thinking Level")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .mobileSheetPresentation()
    }

    private func row(_ title: String, id: String?, detail: String? = nil) -> some View {
        Button {
            MobileHaptics.buttonTap()
            onSelect(id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected == id { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected == id ? .isSelected : [])
    }
}
