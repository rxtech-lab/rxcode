import SwiftUI
import RxCodeCore

extension EnvironmentValues {
    @Entry var jsonUIInteraction: JSONUIInteraction? = nil
    @Entry var jsonUIFormID: String? = nil
}

/// Each renderer owns its form values. A bound MCP submit forwards a snapshot to its host.
@MainActor @Observable
public final class JSONUIInteraction {
    let spec: JSONUISpec
    var values: [String: JSONValue]
    var presented: String?
    var notice: String?
    var feedback = 0
    let onSubmit: (([String: JSONValue]) -> Void)?
    private let nativeApp: (document: MCPJSONUIResource, submit: MCPJSONUISubmit)?
    private var operations: [String: Task<Void, Never>] = [:]
    private(set) var submissions: [String: SubmissionStatus] = [:]

    enum SubmissionStatus: Equatable {
        case pending
        case success(String)
        case failure(String)
    }

    var usesInlineRoot: Bool { nativeApp != nil }

    public init(spec: JSONUISpec, onSubmit: (([String: JSONValue]) -> Void)? = nil) {
        self.spec = spec
        values = spec.initialValues
        self.onSubmit = onSubmit
        nativeApp = nil
        if let root = spec.elements[spec.root], JSONUICatalog.presentationTypes.contains(root.type) {
            presented = spec.root
        }
    }

    init(document: MCPJSONUIResource, submit: @escaping MCPJSONUISubmit) {
        spec = document.spec
        values = spec.initialValues
        onSubmit = nil
        nativeApp = (document, submit)
    }

    func perform(_ raw: JSONValue?, formID: String? = nil, elementID: String? = nil) {
        guard let action = raw?.objectValue, let type = action["type"]?.stringValue else { return }
        if let elementID, operations[elementID] != nil { return }
        feedback += 1
        let scope = (action["target"]?.stringValue ?? formID).map { spec.inputNames(in: $0) }
        switch type {
        case "present":
            guard presented == nil, let target = action["target"]?.stringValue,
                  let element = spec.elements[target], JSONUICatalog.presentationTypes.contains(element.type) else { return }
            notice = nil
            presented = target
        case "dismiss": presented = nil
        case "set":
            if let name = action["name"]?.stringValue, values[name] != nil, let value = action["value"] {
                values[name] = value
                notice = "Value updated locally."
            }
        case "reset":
            for (name, value) in spec.initialValues where scope?.contains(name) ?? true {
                values[name] = value
            }
            notice = "Form reset."
        case "submit":
            let missing = spec.elements.filter { id, field in
                JSONUICatalog.inputTypes.contains(field.type) && (scope?.contains(field.string("name") ?? id) ?? true) && field.bool("required") == true
                    && (values[field.string("name") ?? id]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
            }
            guard missing.isEmpty else {
                notice = "Complete required fields: " + missing.sorted(by: { $0.key < $1.key }).map { $0.value.string("label") ?? $0.key }.joined(separator: ", ")
                return
            }
            let submittedValues = values.filter { scope?.contains($0.key) ?? true }
            if let nativeApp, let id = elementID {
                do {
                    if let context = try nativeApp.document.actionContext(for: id, values: submittedValues) {
                        submit(context, using: nativeApp.submit)
                        return
                    }
                } catch {
                    submissions[id] = .failure(error.localizedDescription)
                    return
                }
            }
            onSubmit?(submittedValues)
            notice = onSubmit == nil ? "Form captured locally. No data was sent." : "Form submitted to the host."
        default: break
        }
    }

    private func submit(_ context: MCPJSONUIActionContext, using handler: @escaping MCPJSONUISubmit) {
        let id = context.actionID
        notice = nil
        submissions[id] = .pending
        operations[id] = Task {
            defer { operations[id] = nil }
            do {
                try Task.checkCancellation()
                let result = try await handler(context)
                try Task.checkCancellation()
                let message = Self.resultDescription(result)
                submissions[id] = result["isError"] == true ? .failure(message) : .success(message)
            } catch {
                submissions[id] = .failure(error is CancellationError ? "Submission cancelled." : error.localizedDescription)
            }
        }
    }

    func cancelSubmissions() {
        for operation in operations.values { operation.cancel() }
    }

    private static func resultDescription(_ result: JSONValue) -> String {
        let text = (result["content"]?.arrayValue ?? []).compactMap { item in
            item["type"] == "text" ? item["text"]?.stringValue : nil
        }.joined(separator: "\n")
        if !text.isEmpty { return text }
        if let value = result["structuredContent"] ?? result["content"],
           let data = try? JSONEncoder().encode(value) { return String(decoding: data, as: UTF8.self) }
        if let text = result.stringValue { return text }
        return result["isError"] == true ? "The tool reported an error." : "Submission completed."
    }
}

struct JSONUIInteractiveHost<Content: View>: View {
    let spec: JSONUISpec
    let content: (String) -> Content
    @State private(set) var interaction: JSONUIInteraction

    init(spec: JSONUISpec, onSubmit: (([String: JSONValue]) -> Void)?, interaction: JSONUIInteraction? = nil, @ViewBuilder content: @escaping (String) -> Content) {
        self.spec = spec
        self.content = content
        _interaction = State(initialValue: interaction ?? JSONUIInteraction(spec: spec, onSubmit: onSubmit))
    }

    private var element: JSONUIElement? { interaction.presented.flatMap { spec.elements[$0] } }

    private func showing(_ types: Set<String>) -> Binding<Bool> {
        Binding(get: { element.map { types.contains($0.type) } ?? false }, set: { if !$0 { interaction.presented = nil } })
    }

    var body: some View {
        rootContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                if interaction.notice != nil {
                    status
                } else if element?.type == "Overlay" {
                    overlayContent
                }
            }
            .sheet(isPresented: showing(["Sheet", "Dialog"])) {
                NavigationStack {
                    ScrollView { presentationContent.padding().frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle(element?.string("title") ?? "Interactive View")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { interaction.perform(["type": "dismiss"]) }
                            }
                        }
                }
                .frame(minWidth: 320, idealWidth: 560, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
                .overlay(alignment: .top) { status }
                .environment(\.jsonUIInteraction, interaction)
            }
            .alert(element?.string("title") ?? "Alert", isPresented: showing(["Alert"]), presenting: element) { alert in
                confirmationButtons(alert)
            } message: { alert in
                Text(alert.string("message") ?? "")
            }
            .confirmationDialog(element?.string("title") ?? "Confirm", isPresented: showing(["ConfirmationDialog"]), titleVisibility: .visible, presenting: element) { dialog in
                confirmationButtons(dialog)
            } message: { dialog in
                Text(dialog.string("message") ?? "")
            }
            .environment(\.jsonUIInteraction, interaction)
            #if os(iOS)
            .sensoryFeedback(.selection, trigger: interaction.feedback)
            #endif
    }

    @ViewBuilder private var rootContent: some View {
        if interaction.usesInlineRoot, let root = spec.elements[spec.root], JSONUICatalog.presentationTypes.contains(root.type) {
            VStack(alignment: .leading, spacing: 12) {
                if let title = root.string("title") { Text(title).font(.headline) }
                if let message = root.string("message") { Text(message) }
                ForEach(root.children, id: \.self) { content($0) }
                if let action = root.props["confirmAction"] {
                    Button(root.string("confirmLabel") ?? "Confirm") { interaction.perform(action) }
                }
            }
        } else {
            content(spec.root)
        }
    }

    private var presentationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(element?.children ?? [], id: \.self) { content($0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var overlayContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(element?.string("title") ?? "Status").font(.headline)
                Spacer()
                Button("Dismiss") { interaction.perform(["type": "dismiss"]) }
            }
            presentationContent
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }

    @ViewBuilder private var status: some View {
        if let notice = interaction.notice {
            HStack(alignment: .top) {
                Text(notice).font(.callout)
                Spacer()
                Button {
                    interaction.notice = nil
                    interaction.feedback += 1
                } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Dismiss status")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
            .accessibilityIdentifier("json-ui-status")
        }
    }

    @ViewBuilder private func confirmationButtons(_ element: JSONUIElement) -> some View {
        if let action = element.props["confirmAction"] {
            Button(element.string("confirmLabel") ?? "Confirm", role: element.bool("destructive") == true ? .destructive : nil) {
                interaction.presented = nil
                interaction.perform(action)
            }
            Button("Cancel", role: .cancel) { interaction.presented = nil }
        } else {
            Button("OK", role: .cancel) { interaction.presented = nil }
        }
    }
}

struct JSONUIControl: View {
    let id: String
    let element: JSONUIElement
    @Bindable var interaction: JSONUIInteraction
    @Environment(\.jsonUIFormID) private var formID

    private var name: String { element.string("name") ?? id }
    private var label: String { element.string("label") ?? name }

    private func binding<T>(_ read: @escaping (JSONValue?) -> T, _ write: @escaping (T) -> JSONValue) -> Binding<T> {
        Binding(get: { read(interaction.values[name]) }, set: {
            interaction.values[name] = write($0)
            if !["TextField", "TextEditor"].contains(element.type) { interaction.feedback += 1 }
        })
    }

    var body: some View {
        control
            .disabled(element.bool("disabled") == true || interaction.submissions[id] == .pending)
            .accessibilityIdentifier("json-ui-control-\(id)")
    }

    @ViewBuilder private var control: some View {
        switch element.type {
        case "Button":
            Button(label, role: element.string("role") == "destructive" ? .destructive : nil) {
                interaction.perform(element.props["action"], formID: formID, elementID: id)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        case "TextField":
            TextField(label, text: binding({ $0?.stringValue ?? "" }, JSONValue.string), prompt: Text(element.string("placeholder") ?? ""))
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
        case "TextEditor":
            VStack(alignment: .leading) {
                Text(label).font(.callout)
                TextEditor(text: binding({ $0?.stringValue ?? "" }, JSONValue.string))
                    .frame(minHeight: 120)
                    .accessibilityLabel(label)
            }
        case "Toggle":
            Toggle(label, isOn: binding({ $0?.boolValue ?? false }, JSONValue.bool))
                .frame(minHeight: 44)
        case "Picker":
            Picker(label, selection: binding({ $0?.stringValue ?? "" }, JSONValue.string)) {
                ForEach(element.strings("options"), id: \.self) { Text($0).tag($0) }
            }
            .frame(minHeight: 44)
        case "Slider":
            let lower = element.number("min") ?? 0
            let upper = element.number("max") ?? 100
            if lower.isFinite, upper.isFinite, lower < upper, (element.number("step") ?? 1) > 0 {
                VStack(alignment: .leading) {
                    Text("\(label): \((interaction.values[name]?.numberValue ?? lower).formatted())")
                    Slider(value: binding({ $0?.numberValue ?? lower }, JSONValue.number), in: lower...upper, step: element.number("step") ?? 1) {
                        Text(label)
                    }
                }
            }
        default: EmptyView()
        }
    }
}
