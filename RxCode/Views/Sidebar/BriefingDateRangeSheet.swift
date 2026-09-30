import SwiftUI
import RxCodeCore

/// Picks a custom inclusive day range for the briefing time filter.
struct BriefingDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let apply: (Date, Date) -> Void

    @State private var start: Date
    @State private var end: Date

    init(initialStart: Date, initialEnd: Date, apply: @escaping (Date, Date) -> Void) {
        self.apply = apply
        _start = State(initialValue: initialStart)
        _end = State(initialValue: initialEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title2)
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Custom Date Range")
                    .font(.title2.weight(.semibold))
            }

            Text("Show briefings created between these days, inclusive.")
                .foregroundStyle(ClaudeTheme.textSecondary)

            Form {
                DatePicker("From", selection: $start, in: ...end, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    apply(start, end)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
