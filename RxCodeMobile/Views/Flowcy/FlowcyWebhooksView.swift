import RxCodeCore
import SwiftUI

nonisolated struct FlowcyWebhook: Identifiable {
    let id: String
    let value: JSONValue
    var name: String { value["name"]?.stringValue ?? "Webhook" }
}

struct FlowcyWebhooksView: View {
    @State private var rows: [FlowcyWebhook] = []
    @State private var loading = false
    @State private var deleting = false
    @State private var error: String?
    @State private var editor: FlowcyWebhook?
    @State private var pendingDelete: FlowcyWebhook?
    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView("No Webhooks", systemImage: "arrow.triangle.branch", description: Text("Create a webhook to receive Flowcy events."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    Button { editor = row; MobileHaptics.buttonTap() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).foregroundStyle(.primary)
                            Text(row.value["active"]?.boolValue == false ? "Paused" : "Active").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { pendingDelete = row; MobileHaptics.attentionNeeded() } }
                }.refreshable { await load() }
            }
        }
        .navigationTitle("Webhooks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Webhook", systemImage: "plus") { editor = FlowcyWebhook(id: "", value: .object([:])); MobileHaptics.buttonTap() }
            }
        }
        .sheet(item: $editor) { webhook in FlowcyWebhookForm(existing: webhook.id.isEmpty ? nil : webhook) { await load() }.mobileSheetPresentation() }
        .confirmationDialog("Delete this webhook?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let item = pendingDelete else { return }
                pendingDelete = nil; deleting = true
                Task {
                    defer { deleting = false }
                    do {
                        _ = try await FlowcyAPI().read("webhooks", method: "DELETE", body: .object(["id": .string(item.id)]))
                        await load(); MobileHaptics.connected()
                    } catch { self.error = error.localizedDescription; MobileHaptics.connectionError() }
                }
            }
        }
        .overlay { if loading || deleting { ProgressView(deleting ? "Deleting webhook…" : "Loading…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .alert("Webhooks", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Retry") { Task { await load() } }; Button("Cancel", role: .cancel) { error = nil } } message: { Text(error ?? "") }
        .task { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            let result = try await FlowcyAPI().read("webhooks")
            try Task.checkCancellation()
            rows = (result["items"]?.arrayValue ?? []).compactMap { value in
                guard let id = value["id"]?.stringValue else { return nil }
                return FlowcyWebhook(id: id, value: value)
            }
            error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct FlowcyWebhookForm: View {
    @Environment(\.dismiss) private var dismiss
    let existing: FlowcyWebhook?
    let onSave: () async -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var secret = ""
    @State private var events: Set<String> = []
    @State private var active = true
    @State private var saving = false
    @State private var error: String?
    private let supported = [("push", "Push"), ("release", "Release Published"), ("pull_request", "Pull Request"), ("issue_created", "Issue Created"), ("ci_update_created", "CI Update Created")]
    var body: some View {
        NavigationStack {
            Form {
                Section("Webhook") {
                    TextField("Name", text: $name)
                    TextField("HTTPS endpoint", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(existing == nil ? "Signing secret (optional)" : "New signing secret (leave blank to keep)", text: $secret)
                    if existing != nil { Toggle("Active", isOn: $active) }
                }
                Section("Events") {
                    ForEach(supported, id: \.0) { key, title in
                        Toggle(title, isOn: Binding(get: { events.contains(key) }, set: { enabled in
                            if enabled { events.insert(key) } else { events.remove(key) }
                            MobileHaptics.buttonTap()
                        }))
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Webhook" : "Edit Webhook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || URL(string: url)?.scheme != "https" || events.isEmpty)
                }
            }
            .overlay { if saving { ProgressView("Saving webhook…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .alert("Could Not Save Webhook", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
            .onAppear {
                guard let existing else { return }
                name = existing.name; url = existing.value["url"]?.stringValue ?? ""
                active = existing.value["active"]?.boolValue ?? true
                events = Set(existing.value["events"]?.arrayValue?.compactMap { $0["type"]?.stringValue } ?? [])
            }
        }.interactiveDismissDisabled(saving)
    }
    private func save() async {
        saving = true; MobileHaptics.buttonTap(); defer { saving = false }
        var fields: [String: JSONValue] = ["name": .string(name), "url": .string(url), "events": .array(events.sorted().map { key in
            existing?.value["events"]?.arrayValue?.first(where: { $0["type"]?.stringValue == key }) ?? .object(["type": .string(key)])
        })]
        if let existing { fields["id"] = .string(existing.id); fields["active"] = .bool(active) }
        if !secret.isEmpty { fields["secret"] = .string(secret) }
        do {
            _ = try await FlowcyAPI().read("webhooks", method: existing == nil ? "POST" : "PATCH", body: .object(fields))
            secret = ""; await onSave(); MobileHaptics.connected(); dismiss()
        } catch { self.error = error.localizedDescription; MobileHaptics.connectionError() }
    }
}
