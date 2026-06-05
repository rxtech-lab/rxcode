import SwiftUI
import RxCodeCore

/// Mutable editing state for a custom menu item, decoupled from the SwiftData
/// `@Model` so the form can edit freely and only commit on Save.
struct CustomMenuDraft: Identifiable {
    let id: String
    var isNew: Bool
    var title: String
    var systemImage: String
    var projectId: UUID?            // nil = all projects
    var surface: CustomMenuItemRecord.Surface
    var actionKind: CustomMenuItemRecord.ActionKind

    // callAPI
    var httpMethod: String
    var urlString: String
    var headers: [HeaderPair]
    var bodyTemplate: String

    // create / continue thread
    var messageTemplate: String
    var targetSessionId: String

    var isEnabled: Bool
    var sortOrder: Int

    struct HeaderPair: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var value: String
    }

    /// A fresh draft for a new item.
    init() {
        id = UUID().uuidString
        isNew = true
        title = ""
        systemImage = "bolt"
        projectId = nil
        surface = .project
        actionKind = .callAPI
        httpMethod = "POST"
        urlString = ""
        headers = []
        bodyTemplate = ""
        messageTemplate = ""
        targetSessionId = ""
        isEnabled = true
        sortOrder = 0
    }

    /// A draft seeded from an existing record (edit flow).
    init(record: CustomMenuItemRecord) {
        id = record.id
        isNew = false
        title = record.title
        systemImage = record.systemImage ?? "bolt"
        projectId = record.projectId
        surface = record.surfaceValue
        actionKind = record.actionKindValue
        httpMethod = record.httpMethod ?? "POST"
        urlString = record.urlString ?? ""
        headers = record.headers.map { HeaderPair(name: $0.key, value: $0.value) }
        bodyTemplate = record.bodyTemplate ?? ""
        messageTemplate = record.messageTemplate ?? ""
        targetSessionId = record.targetSessionId ?? ""
        isEnabled = record.isEnabled
        sortOrder = record.sortOrder
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool {
        guard !trimmedTitle.isEmpty else { return false }
        switch actionKind {
        case .callAPI: return !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .createThread: return !messageTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .continueThread:
            guard !messageTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            // A thread-menu item continues the tapped thread, so no explicit target
            // is needed; project/briefing items must name the thread to continue.
            if surface == .thread { return true }
            return !targetSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func toRecord() -> CustomMenuItemRecord {
        let headerMap = headers.reduce(into: [String: String]()) { acc, pair in
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            acc[name] = pair.value
        }
        return CustomMenuItemRecord(
            id: id,
            title: trimmedTitle,
            systemImage: systemImage.isEmpty ? nil : systemImage,
            projectId: projectId,
            surface: surface,
            actionKind: actionKind,
            httpMethod: actionKind == .callAPI ? httpMethod : nil,
            urlString: actionKind == .callAPI ? urlString.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            headersJSON: actionKind == .callAPI ? CustomMenuItemRecord.encodeHeaders(headerMap) : nil,
            bodyTemplate: actionKind == .callAPI ? bodyTemplate : nil,
            messageTemplate: actionKind == .callAPI ? nil : messageTemplate,
            targetSessionId: actionKind == .continueThread ? targetSessionId.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            isEnabled: isEnabled,
            sortOrder: sortOrder
        )
    }
}

/// Form for creating / editing a custom menu item.
struct CustomMenuEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: CustomMenuDraft
    let projects: [Project]
    var onSave: (CustomMenuDraft) -> Void

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.isNew ? "New Menu Item" : "Edit Menu Item")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Form {
                generalSection
                actionSection
                switch draft.actionKind {
                case .callAPI: apiSection
                case .createThread, .continueThread: threadSection
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 540, height: 600)
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section("General") {
            TextField("Title", text: $draft.title)
            LabeledContent("Icon") {
                SFSymbolPicker(symbol: $draft.systemImage)
            }
            .help("An SF Symbol shown beside the title, e.g. \"bolt\".")
            Picker("Show in", selection: $draft.surface) {
                Text("Project menu").tag(CustomMenuItemRecord.Surface.project)
                Text("Thread menu").tag(CustomMenuItemRecord.Surface.thread)
                Text("Briefing card menu").tag(CustomMenuItemRecord.Surface.briefing)
            }
            Picker("Scope", selection: $draft.projectId) {
                Text("All projects").tag(UUID?.none)
                ForEach(projects) { project in
                    Text(verbatim: project.name).tag(UUID?.some(project.id))
                }
            }
        }
    }

    private var actionSection: some View {
        Section("Action") {
            Picker("When tapped", selection: $draft.actionKind) {
                Text("Call external API").tag(CustomMenuItemRecord.ActionKind.callAPI)
                Text("Create new thread").tag(CustomMenuItemRecord.ActionKind.createThread)
                Text("Continue existing thread").tag(CustomMenuItemRecord.ActionKind.continueThread)
            }
            .pickerStyle(.menu)
        }
    }

    private var apiSection: some View {
        Section("Request") {
            Picker("Method", selection: $draft.httpMethod) {
                ForEach(methods, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            TextField("URL", text: $draft.urlString, prompt: Text(verbatim: "https://api.example.com/{{projectName}}"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ClaudeTheme.size(12), design: .monospaced))

            headersEditor

            VStack(alignment: .leading, spacing: 4) {
                Text("Body")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.bodyTemplate)
                    .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor)))
            }
        }
    }

    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Headers")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    draft.headers.append(.init(name: "", value: ""))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            ForEach($draft.headers) { $pair in
                HStack(spacing: 6) {
                    TextField("Name", text: $pair.name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Value", text: $pair.value)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        draft.headers.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var threadSection: some View {
        Section(draft.actionKind == .continueThread ? "Continue thread" : "New thread") {
            if draft.actionKind == .continueThread {
                TextField("Target thread id", text: $draft.targetSessionId)
                    .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
                    .help("The session id of the thread to continue. Leave a {{sessionId}} placeholder to target the tapped thread.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Message")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.messageTemplate)
                    .font(.system(size: ClaudeTheme.size(12)))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor)))
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!draft.isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
