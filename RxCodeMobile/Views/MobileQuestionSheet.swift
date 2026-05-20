import SwiftUI
import UIKit
import RxCodeCore
import RxCodeSync

/// Sheet UI for an `AskUserQuestion` tool call mirrored from the desktop.
/// Displays every question in the payload behind a navigator of pills, lets the
/// user answer each (single-select, multi-select, or free-form "Other" text),
/// then submits all answers at once. Mirrors the desktop `QuestionSheetView`.
struct MobileQuestionSheet: View {
    let request: PendingQuestionPayload
    /// Other question requests still queued for the same session, shown as a
    /// "+N more pending" hint in the header.
    let remainingCount: Int
    let onSubmit: (_ answers: [Int: AskUserQuestion.Answer]) -> Void
    /// Resolves the tool call as denied — "Skip All Questions".
    let onSkipAll: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var answers: [Int: LocalAnswer] = [:]
    @State private var currentQuestionIndex: Int = 0
    @State private var isSubmitting: Bool = false

    private var parsed: AskUserQuestion? {
        guard let data = request.toolInputJSON.data(using: .utf8),
              let input = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }
        return AskUserQuestion(input: input)
    }

    private var questions: [AskUserQuestion.Question] {
        parsed?.questions ?? []
    }

    private var totalQuestions: Int { questions.count }

    private var isLastQuestion: Bool {
        currentQuestionIndex >= totalQuestions - 1
    }

    private var currentQuestion: AskUserQuestion.Question? {
        guard currentQuestionIndex < questions.count else { return nil }
        return questions[currentQuestionIndex]
    }

    private var currentAnswerProvided: Bool {
        guard let question = currentQuestion else { return false }
        return isAnswered(answers[currentQuestionIndex], for: question)
    }

    private var allAnswered: Bool {
        questions.enumerated().allSatisfy { index, question in
            isAnswered(answers[index], for: question)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if totalQuestions > 1 {
                questionNavigator
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if let question = currentQuestion {
                        questionContent(index: currentQuestionIndex, question: question)
                            .id(currentQuestionIndex)
                    } else {
                        fallbackEmpty
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            bottomActionBar
        }
        .background(ClaudeTheme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Local Answer Storage

private enum LocalAnswer {
    case singleChoice(String)
    case multipleChoice(Set<String>)
    case otherText(String)
    /// Multi-select where the user toggled "Other" — `selectedLabels` are real
    /// options, `otherText` is the free-form value (may be empty until typed).
    case multipleChoiceWithOther(selectedLabels: Set<String>, otherText: String)
}

private extension MobileQuestionSheet {
    func isAnswered(_ answer: LocalAnswer?, for question: AskUserQuestion.Question) -> Bool {
        guard let answer else { return false }
        switch answer {
        case .singleChoice(let label):
            return !label.isEmpty
        case .multipleChoice(let labels):
            return !labels.isEmpty
        case .otherText(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .multipleChoiceWithOther(let labels, let text):
            return !labels.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - Top Bar

private extension MobileQuestionSheet {
    var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(ClaudeTheme.accentSubtle)
                    .frame(width: 34, height: 34)
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Assistant has a question")
                    .font(.headline)
                    .foregroundStyle(ClaudeTheme.textPrimary)
                if remainingCount > 0 {
                    Text("+\(remainingCount) more pending")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ClaudeTheme.surfaceSecondary))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel("Close — answer later from the queue")
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

// MARK: - Navigator

private extension MobileQuestionSheet {
    var questionNavigator: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        questionPill(index: index, question: question)
                            .id(index)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: currentQuestionIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    func questionPill(index: Int, question: AskUserQuestion.Question) -> some View {
        let isActive = index == currentQuestionIndex
        let answered = isAnswered(answers[index], for: question)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentQuestionIndex = index
            }
        } label: {
            HStack(spacing: 6) {
                if answered {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(pillLabel(index: index, question: question))
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive || answered ? Color.white : ClaudeTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(pillColor(isActive: isActive, answered: answered)))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    func pillLabel(index: Int, question: AskUserQuestion.Question) -> String {
        if totalQuestions <= 3 {
            let title = question.header ?? question.question
            return title.count > 22 ? String(title.prefix(20)) + "…" : title
        }
        return "Q\(index + 1)"
    }

    func pillColor(isActive: Bool, answered: Bool) -> Color {
        if isActive { return ClaudeTheme.accent }
        if answered { return ClaudeTheme.accent.opacity(0.6) }
        return ClaudeTheme.surfaceSecondary
    }
}

// MARK: - Question Content

private extension MobileQuestionSheet {
    @ViewBuilder
    func questionContent(index: Int, question: AskUserQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            questionHeader(question: question)
                .padding(.bottom, 14)
            Divider()
                .padding(.bottom, 14)
            if question.multiSelect {
                multipleChoiceInput(index: index, question: question)
            } else {
                singleChoiceInput(index: index, question: question)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge)
                .strokeBorder(ClaudeTheme.border, lineWidth: 0.5)
        )
    }

    func questionHeader(question: AskUserQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: question.multiSelect ? "checklist" : "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(ClaudeTheme.accentSubtle))
                Text(question.multiSelect ? "Select all that apply" : "Choose one")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                if totalQuestions > 1 {
                    Text("\(currentQuestionIndex + 1)/\(totalQuestions)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .monospacedDigit()
                }
            }
            if let header = question.header, !header.isEmpty {
                Text(header)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .padding(.top, 4)
            }
            Text(question.question)
                .font(.system(size: 14))
                .foregroundStyle(ClaudeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Single-choice

    func singleChoiceInput(index: Int, question: AskUserQuestion.Question) -> some View {
        let currentSelection: String? = {
            if case .singleChoice(let label) = answers[index] { return label }
            return nil
        }()
        let isOtherActive: Bool = {
            if case .otherText = answers[index] { return true }
            return false
        }()
        return VStack(spacing: 8) {
            ForEach(question.options) { option in
                ChoiceRow(
                    title: option.label,
                    description: option.description,
                    isSelected: currentSelection == option.label,
                    style: .radio
                ) {
                    answers[index] = .singleChoice(option.label)
                }
            }
            ChoiceRow(
                title: "Other",
                description: nil,
                isSelected: isOtherActive,
                style: .radio
            ) {
                answers[index] = .otherText("")
            }
            if isOtherActive {
                otherTextField(
                    text: Binding(
                        get: {
                            if case .otherText(let v) = answers[index] { return v }
                            return ""
                        },
                        set: { answers[index] = .otherText($0) }
                    )
                )
            }
        }
        .disabled(isSubmitting)
    }

    // MARK: Multi-choice

    func multipleChoiceInput(index: Int, question: AskUserQuestion.Question) -> some View {
        let selected: Set<String> = {
            switch answers[index] {
            case .multipleChoice(let s): return s
            case .multipleChoiceWithOther(let s, _): return s
            default: return []
            }
        }()
        let otherActive: Bool = {
            if case .multipleChoiceWithOther = answers[index] { return true }
            return false
        }()
        let otherText: String = {
            if case .multipleChoiceWithOther(_, let t) = answers[index] { return t }
            return ""
        }()

        return VStack(spacing: 8) {
            ForEach(question.options) { option in
                ChoiceRow(
                    title: option.label,
                    description: option.description,
                    isSelected: selected.contains(option.label),
                    style: .checkbox
                ) {
                    var newSet = selected
                    if newSet.contains(option.label) {
                        newSet.remove(option.label)
                    } else {
                        newSet.insert(option.label)
                    }
                    if otherActive {
                        answers[index] = .multipleChoiceWithOther(selectedLabels: newSet, otherText: otherText)
                    } else {
                        answers[index] = .multipleChoice(newSet)
                    }
                }
            }
            ChoiceRow(
                title: "Other",
                description: nil,
                isSelected: otherActive,
                style: .checkbox
            ) {
                if otherActive {
                    answers[index] = .multipleChoice(selected)
                } else {
                    answers[index] = .multipleChoiceWithOther(selectedLabels: selected, otherText: "")
                }
            }
            if otherActive {
                otherTextField(
                    text: Binding(
                        get: { otherText },
                        set: { answers[index] = .multipleChoiceWithOther(selectedLabels: selected, otherText: $0) }
                    )
                )
            }
        }
        .disabled(isSubmitting)
    }

    func otherTextField(text: Binding<String>) -> some View {
        TextField("Type your answer…", text: text, axis: .vertical)
            .lineLimit(2 ... 6)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(ClaudeTheme.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .strokeBorder(ClaudeTheme.inputBorder, lineWidth: 1)
            )
    }

    var fallbackEmpty: some View {
        VStack(spacing: 8) {
            Text("Malformed question payload")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ClaudeTheme.statusError)
            Text("The desktop sent an AskUserQuestion call this app could not parse.")
                .font(.system(size: 13))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }
}

// MARK: - Bottom Action Bar

private extension MobileQuestionSheet {
    var bottomActionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if currentQuestionIndex > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentQuestionIndex -= 1
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .frame(width: 48, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                                    .fill(ClaudeTheme.surfaceSecondary)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                }
                Button {
                    if isLastQuestion || allAnswered {
                        submit()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentQuestionIndex += 1
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(mainButtonLabel)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        if !isSubmitting {
                            Image(systemName: mainButtonIcon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                            .fill(submitEnabled ? ClaudeTheme.accent : ClaudeTheme.textTertiary)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!submitEnabled)
            }
            Button(role: .destructive) {
                isSubmitting = true
                onSkipAll()
                dismiss()
            } label: {
                Text("Skip All Questions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            Rectangle().fill(ClaudeTheme.surfacePrimary)
                .overlay(alignment: .top) {
                    Rectangle().fill(ClaudeTheme.border).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    var submitEnabled: Bool {
        guard !isSubmitting else { return false }
        if isLastQuestion || allAnswered { return allAnswered }
        return currentAnswerProvided
    }

    var mainButtonLabel: String {
        (isLastQuestion || allAnswered) ? "Submit" : "Next"
    }

    var mainButtonIcon: String {
        (isLastQuestion || allAnswered) ? "paperplane.fill" : "arrow.right"
    }

    func submit() {
        guard allAnswered, !isSubmitting else { return }
        isSubmitting = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        var resolved: [Int: AskUserQuestion.Answer] = [:]
        for (index, question) in questions.enumerated() {
            guard let local = answers[index] else { continue }
            resolved[index] = convert(local: local, multiSelect: question.multiSelect)
        }
        onSubmit(resolved)
        dismiss()
    }

    func convert(local: LocalAnswer, multiSelect: Bool) -> AskUserQuestion.Answer {
        switch local {
        case .singleChoice(let label):
            return .single(label)
        case .otherText(let text):
            return .single("Other: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .multipleChoice(let labels):
            return .multi(labels.sorted())
        case .multipleChoiceWithOther(let labels, let text):
            var values = labels.sorted()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                values.append("Other: \(trimmed)")
            }
            return multiSelect ? .multi(values) : .single(values.joined(separator: ", "))
        }
    }
}

// MARK: - Choice Row

private struct ChoiceRow: View {
    enum Style {
        case radio, checkbox

        var selectedIcon: String {
            switch self {
            case .radio: return "largecircle.fill.circle"
            case .checkbox: return "checkmark.square.fill"
            }
        }

        var deselectedIcon: String {
            switch self {
            case .radio: return "circle"
            case .checkbox: return "square"
            }
        }
    }

    let title: String
    let description: String?
    let isSelected: Bool
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? style.selectedIcon : style.deselectedIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? ClaudeTheme.accent : ClaudeTheme.textSecondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .fill(isSelected ? ClaudeTheme.accentSubtle : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall)
                    .strokeBorder(isSelected ? ClaudeTheme.accent.opacity(0.45) : ClaudeTheme.border,
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
