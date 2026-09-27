import RxCodeCore
import SwiftUI

/// Edits one schedule independently of the scheduled task form.
struct CronScheduleEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let projectId: UUID?
    let onSave: (String) -> Void
    @State private var expression: String
    @State private var visual: CronVisualSchedule
    @State private var mode: Mode
    @State private var showsAI = false
    @State private var aiDescription = ""
    @State private var aiModel: GeneralAIModel = .taskAgent
    @State private var isGenerating = false
    @State private var aiError: String?

    private enum Mode: Hashable { case builder, expression }

    init(expression: String, projectId: UUID?, onSave: @escaping (String) -> Void) {
        self.projectId = projectId
        self.onSave = onSave
        _expression = State(initialValue: expression)
        let parsed = CronVisualSchedule.parse(expression)
        _visual = State(initialValue: parsed)
        _mode = State(initialValue: parsed.frequency == .custom ? .expression : .builder)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Input", selection: $mode) {
                        Text("Builder").tag(Mode.builder)
                        Text("Expression").tag(Mode.expression)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("cron-editor-mode")

                    if mode == .builder {
                        builder
                    } else {
                        TextField("Cron expression", text: $expression, prompt: Text("0 9 * * 1-5"))
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("cron-editor-expression")
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Times use your local time zone. Advanced cron expressions remain available in Expression mode.")
                }

                Section {
                    HStack {
                        Text(expression)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            showsAI = true
                        } label: {
                            Label("Write with AI", systemImage: "sparkles")
                        }
                        .popover(isPresented: $showsAI, arrowEdge: .trailing) { aiPopover }
                        .accessibilityIdentifier("cron-editor-ai")
                    }
                    preview
                } header: {
                    Text("Expression and next runs")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Schedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(expression.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(!CronExpression.isValid(expression))
                    .accessibilityIdentifier("cron-editor-done")
                }
            }
        }
        .frame(width: 500, height: 520)
        .onAppear { aiModel = appState.generalAIModel() }
        .onChange(of: visual) { _, newValue in
            if mode == .builder, let generated = newValue.expression {
                expression = generated
            }
        }
        .onChange(of: visual.frequency) { _, frequency in
            if frequency == .everyNHours, visual.interval > 23 { visual.interval = 6 }
        }
        .onChange(of: expression) { _, newValue in
            guard newValue != visual.expression else { return }
            let parsed = CronVisualSchedule.parse(newValue)
            visual = parsed
            if parsed.frequency == .custom { mode = .expression }
        }
    }

    private var builder: some View {
        Group {
            Picker("Frequency", selection: $visual.frequency) {
                Text("Choose frequency").tag(CronVisualSchedule.Frequency.custom)
                Text("Every minute").tag(CronVisualSchedule.Frequency.everyMinute)
                Text("Every N minutes").tag(CronVisualSchedule.Frequency.everyNMinutes)
                Text("Every hour").tag(CronVisualSchedule.Frequency.everyHour)
                Text("Every N hours").tag(CronVisualSchedule.Frequency.everyNHours)
                Text("Daily").tag(CronVisualSchedule.Frequency.daily)
                Text("Specific days").tag(CronVisualSchedule.Frequency.specificDays)
                Text("Weekly").tag(CronVisualSchedule.Frequency.weekly)
                Text("Monthly").tag(CronVisualSchedule.Frequency.monthly)
            }
            .accessibilityIdentifier("cron-editor-frequency")

            switch visual.frequency {
            case .everyNMinutes:
                Picker("Every", selection: $visual.interval) {
                    ForEach(1...59, id: \.self) { value in
                        Text("\(value) minutes").tag(value)
                    }
                }
            case .everyNHours:
                Picker("Every", selection: $visual.interval) {
                    ForEach(1...23, id: \.self) { value in
                        Text("\(value) hours").tag(value)
                    }
                }
            case .daily, .specificDays, .weekly, .monthly:
                HStack {
                    Text("At")
                    Spacer()
                    Picker("Hour", selection: $visual.hour) {
                        ForEach(0..<24, id: \.self) { value in
                            Text(String(format: "%02d", value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    Text(":")
                    Picker("Minute", selection: $visual.minute) {
                        ForEach(0..<60, id: \.self) { value in
                            Text(String(format: "%02d", value)).tag(value)
                        }
                    }
                    .labelsHidden()
                }
            case .custom:
                Text("Choose a frequency to replace this custom expression.")
                    .foregroundStyle(.secondary)
            default: EmptyView()
            }

            if visual.frequency == .specificDays {
                weekdays
            } else if visual.frequency == .weekly {
                Picker("Day", selection: Binding(
                    get: { visual.weekdays.sorted().first ?? 1 },
                    set: { visual.weekdays = [$0] }
                )) {
                    ForEach(0..<7, id: \.self) { day in
                        Text(Self.weekdayNames[day]).tag(day)
                    }
                }
            } else if visual.frequency == .monthly {
                Picker("Day of month", selection: $visual.dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in
                        Text("\(day)").tag(day)
                    }
                }
            }
        }
    }

    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let shortWeekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var weekdays: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Days")
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { day in
                    Button(Self.shortWeekdayNames[day]) {
                        if visual.weekdays.contains(day) {
                            if visual.weekdays.count > 1 { visual.weekdays.remove(day) }
                        } else {
                            visual.weekdays.insert(day)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(visual.weekdays.contains(day) ? .accentColor : .secondary)
                    .accessibilityIdentifier("cron-editor-day-\(day)")
                }
            }
        }
    }

    private var parseResult: Result<CronExpression, CronExpression.ParseError> {
        Result { () throws(CronExpression.ParseError) in try CronExpression(expression) }
    }

    @ViewBuilder
    private var preview: some View {
        switch parseResult {
        case .success(let cron):
            if let first = cron.nextDate(after: .now) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next runs")
                        .font(.caption.weight(.semibold))
                    Text(first.formatted(date: .complete, time: .shortened))
                    if let second = cron.nextDate(after: first) {
                        Text(second.formatted(date: .complete, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label("This schedule never runs.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(ClaudeTheme.statusWarning)
            }
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ClaudeTheme.statusError)
        }
    }

    private var aiPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Write a schedule with AI")
                .font(.headline)
            TextField("For example, every weekday at 9 AM", text: $aiDescription)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await generate() } }
                .accessibilityIdentifier("cron-editor-ai-description")
            HStack {
                Text("AI model")
                Spacer()
                SuggestionAgentMenu(agent: $aiModel, persistsSelection: false)
                    .disabled(isGenerating)
                    .accessibilityIdentifier("cron-editor-ai-model")
            }
            if let aiError {
                Label(aiError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.statusError)
            }
            HStack {
                Spacer()
                Button("Cancel") { showsAI = false }
                    .disabled(isGenerating)
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating { ProgressView().controlSize(.small) }
                    else { Text("Generate") }
                }
                .disabled(isGenerating || aiDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("cron-editor-ai-generate")
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func generate() async {
        let description = aiDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !isGenerating else { return }
        isGenerating = true
        aiError = nil
        let selectedModel = aiModel
        let generated = await appState.suggestCronExpression(
            description: description, projectId: projectId, model: selectedModel
        )
        isGenerating = false
        guard aiDescription.trimmingCharacters(in: .whitespacesAndNewlines) == description else { return }
        if let generated {
            expression = generated
            showsAI = false
        } else {
            aiError = String(localized: "Could not generate a cron expression. Try rewording the schedule.")
        }
    }
}
