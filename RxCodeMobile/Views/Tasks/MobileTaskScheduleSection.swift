import RxCodeCore
import SwiftUI

/// Deadline, size, delays and reviewer for a story or task form.
struct MobileTaskScheduleSection: View {
    @Binding var deadline: Date?
    @Binding var size: TaskSize?
    @Binding var delays: [TaskDelay]
    /// Who moved the task from Pending Review to done. Tasks only.
    var reviewer: CardAssignee?
    /// Recorded as a new delay's author. Nil leaves it for the Mac to stamp.
    var actor: CardAssignee?

    @State private var addingDelay = false
    @State private var pendingRemoval: TaskDelay?

    var body: some View {
        Section("Schedule") {
            Toggle("Deadline", isOn: hasDeadline)
                .accessibilityIdentifier("task-form-deadline-toggle")
            if let current = deadline {
                DatePicker(
                    "Due",
                    selection: Binding(get: { current }, set: { deadline = $0 }),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            Picker("Size", selection: $size) {
                Text("None").tag(TaskSize?.none)
                ForEach(TaskSize.allCases, id: \.self) { size in
                    Text("\(size.shortName) · \(size.displayNameText)").tag(TaskSize?.some(size))
                }
            }
            .accessibilityIdentifier("task-form-size")
            if let reviewer {
                LabeledContent("Reviewer", value: reviewer.displayName)
            }
        }
        .sensoryFeedback(.selection, trigger: size)
        .sensoryFeedback(.selection, trigger: deadline == nil)

        Section {
            ForEach(delays.reversed()) { delay in
                VStack(alignment: .leading, spacing: 2) {
                    Text(delay.reason)
                    Text(byline(delay))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        pendingRemoval = delay
                    }
                }
            }
            Button("Add Delay", systemImage: "clock.badge.exclamationmark") {
                MobileHaptics.buttonTap()
                addingDelay = true
            }
            .accessibilityIdentifier("task-form-add-delay")
        } header: {
            Text("Delays")
        }
        .sheet(isPresented: $addingDelay) {
            MobileTaskDelaySheet { reason in
                delays.append(TaskDelay(reason: reason, author: actor))
            }
        }
        .confirmationDialog(
            "Remove this delay?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { delay in
            Button("Remove Delay", role: .destructive) {
                MobileHaptics.buttonTap()
                delays.removeAll { $0.id == delay.id }
            }
        } message: { delay in
            Text(delay.reason)
        }
    }

    private var hasDeadline: Binding<Bool> {
        Binding(
            get: { deadline != nil },
            set: { isOn in
                guard isOn else { deadline = nil; return }
                let calendar = Calendar.current
                let nextWeek = calendar.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                deadline = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: nextWeek) ?? nextWeek
            }
        )
    }

    private func byline(_ delay: TaskDelay) -> String {
        let time = delay.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let author = delay.author else { return time }
        return String(localized: "\(author.displayName) · \(time)")
    }
}

/// Records why a story or task slipped, in its own sheet.
private struct MobileTaskDelaySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    let onAdd: (String) -> Void

    private var trimmedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why is this delayed?", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("task-delay-reason")
                } footer: {
                    Text("The delay is recorded with your name and the current time.")
                }
            }
            .navigationTitle("Add Delay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        MobileHaptics.buttonTap()
                        onAdd(trimmedReason)
                        dismiss()
                    }
                    .disabled(trimmedReason.isEmpty)
                    .accessibilityIdentifier("task-delay-add")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
