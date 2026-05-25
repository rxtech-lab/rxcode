import SwiftUI
import RxCodeCore
import RxCodeSync

/// Manage the global MCP servers configured on the paired desktop.
struct MobileMCPServersView: View {
    @EnvironmentObject private var state: MobileAppState
    @State private var editing: MobileMCPServer?
    @State private var showingAdd = false
    @State private var pendingRemoval: MobileMCPServer?

    var body: some View {
        List {
            if let error = state.mcpConfigError {
                errorRow(error)
            }
            if let error = state.lastMCPError {
                errorRow(error)
            }

            if state.mcpServers.isEmpty {
                emptyOrLoadingRow
            } else {
                ForEach(state.mcpServers) { server in
                    row(server)
                }
            }
        }
        .navigationTitle("MCP Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await state.requestMCPConfig()
        }
        .task {
            if state.mcpServers.isEmpty {
                await state.requestMCPConfig()
            }
        }
        .sheet(isPresented: $showingAdd) {
            MobileMCPServerFormView(existing: nil)
                .environmentObject(state)
                .mobileSheetPresentation()
        }
        .sheet(item: $editing) { server in
            MobileMCPServerFormView(existing: server)
                .environmentObject(state)
                .mobileSheetPresentation()
        }
        .alert(
            "Remove MCP server?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let server = pendingRemoval {
                    Task { await state.removeMCPServer(server.name) }
                }
                pendingRemoval = nil
            }
        } message: {
            if let server = pendingRemoval {
                Text("This removes \(server.name) from your Mac's global MCP configuration.")
            }
        }
    }

    private func row(_ server: MobileMCPServer) -> some View {
        Button {
            editing = server
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(server.transport.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if !server.endpoint.isEmpty {
                        Text(server.endpoint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if state.inFlightMCPMutations.contains(server.name) {
                    ProgressView()
                } else {
                    Toggle("", isOn: Binding(
                        get: { server.isGloballyEnabled },
                        set: { value in Task { await state.setMCPServerEnabled(server.name, enabled: value) } }
                    ))
                    .labelsHidden()
                }
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) {
                pendingRemoval = server
            }
        }
    }

    @ViewBuilder
    private var emptyOrLoadingRow: some View {
        if state.mcpConfigLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
        } else if state.mcpConfigError == nil {
            Text("No MCP servers configured. Tap + to add one.")
                .foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}

/// Add or edit a global MCP server. The desktop upserts by name, so editing an
/// existing server reuses the add path; the name field is locked when editing.
struct MobileMCPServerFormView: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss

    let existing: MobileMCPServer?

    @State private var name = ""
    @State private var transport = "stdio"
    @State private var command = ""
    @State private var url = ""
    @State private var args: [DraftField] = []
    @State private var env: [DraftPair] = []
    @State private var headers: [DraftPair] = []

    private struct DraftField: Identifiable {
        let id = UUID()
        var value: String
    }

    private struct DraftPair: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    private var isStdio: Bool { transport == "stdio" }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isStdio {
            return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .disabled(existing != nil)
                    Picker("Transport", selection: $transport) {
                        Text("stdio").tag("stdio")
                        Text("HTTP").tag("http")
                        Text("SSE").tag("sse")
                    }
                }

                if isStdio {
                    Section("Command") {
                        TextField("Command", text: $command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                    Section("Arguments") {
                        ForEach($args) { $field in
                            TextField("Argument", text: $field.value)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                        .onDelete { args.remove(atOffsets: $0) }
                        Button {
                            args.append(DraftField(value: ""))
                        } label: {
                            Label("Add Argument", systemImage: "plus")
                        }
                    }
                    keyValueSection(title: "Environment Variables", items: $env, addLabel: "Add Variable")
                } else {
                    Section("Endpoint") {
                        TextField("URL", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                    }
                    keyValueSection(title: "Headers", items: $headers, addLabel: "Add Header")
                }
            }
            .navigationTitle(existing == nil ? "Add MCP Server" : "Edit MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private func keyValueSection(
        title: String,
        items: Binding<[DraftPair]>,
        addLabel: String
    ) -> some View {
        Section(title) {
            ForEach(items) { $pair in
                HStack(spacing: 8) {
                    TextField("Key", text: $pair.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Divider()
                    TextField("Value", text: $pair.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .onDelete { items.wrappedValue.remove(atOffsets: $0) }
            Button {
                items.wrappedValue.append(DraftPair(key: "", value: ""))
            } label: {
                Label(addLabel, systemImage: "plus")
            }
        }
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        transport = existing.transport
        command = existing.command ?? ""
        url = existing.url ?? ""
        args = existing.args.map { DraftField(value: $0) }
        env = existing.env.map { DraftPair(key: $0.key, value: $0.value) }
        headers = existing.headers.map { DraftPair(key: $0.key, value: $0.value) }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArgs = args
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanEnv = env.compactMap { pair -> MobileMCPKeyValue? in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : MobileMCPKeyValue(key: key, value: pair.value)
        }
        let cleanHeaders = headers.compactMap { pair -> MobileMCPKeyValue? in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : MobileMCPKeyValue(key: key, value: pair.value)
        }
        let endpoint = isStdio
            ? ([trimmedCommand] + cleanArgs).filter { !$0.isEmpty }.joined(separator: " ")
            : trimmedURL

        let server = MobileMCPServer(
            name: trimmedName,
            transport: transport,
            url: isStdio ? nil : trimmedURL,
            command: isStdio ? trimmedCommand : nil,
            args: isStdio ? cleanArgs : [],
            env: isStdio ? cleanEnv : [],
            headers: isStdio ? [] : cleanHeaders,
            isGloballyEnabled: existing?.isGloballyEnabled ?? true,
            endpoint: endpoint
        )
        Task { await state.addMCPServer(server) }
        dismiss()
    }
}
