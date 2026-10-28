import RxCodeCore
import SwiftUI

/// Deadline, size, delays and reviewer: the schedule fields shared by stories
/// and tasks.
extension TaskFormSheet {
    var scheduleSection: some View {
        Section("Schedule") {
            Toggle("Deadline", isOn: hasDeadline)
            if let deadline = field(\.deadline, \.deadline).wrappedValue {
                DatePicker(
                    "Due",
                    selection: Binding(
                        get: { deadline },
                        set: { field(\.deadline, \.deadline).wrappedValue = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            Picker("Size", selection: field(\.size, \.size)) {
                Text("None").tag(TaskSize?.none)
                ForEach(TaskSize.allCases, id: \.self) { size in
                    Text("\(size.shortName) · \(size.displayNameText)").tag(TaskSize?.some(size))
                }
            }

            if !isStory, let reviewer = task.reviewer {
                LabeledContent("Reviewer") {
                    CardAssigneesView(ids: [reviewer.userId], profiles: [reviewer])
                }
                .help("Moved this task from Pending Review to done")
            }

            LabeledContent("Delays") {
                Button {
                    addingDelay = true
                } label: {
                    Label("Add Delay", systemImage: "plus")
                }
                .accessibilityIdentifier("task-form-add-delay")
            }
            ForEach(field(\.delays, \.delays).wrappedValue.reversed()) { delay in
                TaskDelayRow(delay: delay) {
                    pendingDelayRemoval = delay
                }
            }
        }
        .sheet(isPresented: $addingDelay) {
            TaskDelaySheet { reason in
                field(\.delays, \.delays).wrappedValue.append(
                    TaskDelay(reason: reason, author: appState.cardActor)
                )
            }
        }
        .confirmationDialog(
            "Remove this delay?",
            isPresented: Binding(
                get: { pendingDelayRemoval != nil },
                set: { if !$0 { pendingDelayRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelayRemoval
        ) { delay in
            Button("Remove Delay", role: .destructive) {
                field(\.delays, \.delays).wrappedValue.removeAll { $0.id == delay.id }
            }
            Button("Cancel", role: .cancel) {}
        } message: { delay in
            Text(delay.reason)
        }
    }

    private var hasDeadline: Binding<Bool> {
        Binding(
            get: { field(\.deadline, \.deadline).wrappedValue != nil },
            set: { isOn in
                field(\.deadline, \.deadline).wrappedValue = isOn ? Self.defaultDeadline() : nil
            }
        )
    }

    /// One week out, at the end of the working day.
    private static func defaultDeadline() -> Date {
        let calendar = Calendar.current
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: nextWeek) ?? nextWeek
    }
}

/// One recorded delay in the form: the reason, who added it and when.
private struct TaskDelayRow: View {
    let delay: TaskDelay
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(ClaudeTheme.statusWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text(delay.reason)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(TaskDelayRow.byline(delay))
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove Delay")
            .accessibilityLabel("Remove Delay")
        }
    }

    static func byline(_ delay: TaskDelay) -> String {
        let time = delay.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let author = delay.author else { return time }
        return String(localized: "\(author.displayName) · \(time)")
    }
}

/// Records why a story or task slipped. Its own sheet so the form stays a
/// single-purpose edit view.
private struct TaskDelaySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    let onAdd: (String) -> Void

    private var trimmedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Reason", text: $reason, prompt: Text("Why is this delayed?"), axis: .vertical)
                        .lineLimit(3...8)
                        .multilineTextAlignment(.leading)
                } header: {
                    Text("Add Delay")
                } footer: {
                    Text("The delay is recorded with your name and the current time.")
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(trimmedReason)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedReason.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 300)
    }
}
