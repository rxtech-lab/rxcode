import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PetLooksPane: View {
    let controller: PetController
    @State private var editing: PetLook?
    @State private var creating: PetLookCreationSession?
    @State private var previewing: PetLook?
    @State private var removing: PetLook?
    @State private var importing = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a look, or ask your pet to create one in chat.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Create with Prompt…") { creating = PetLookCreationSession() }
                Button("Import Pack…") { importing = true }
                Button("New Look…") { duplicate(controller.looks.selected) }
            }
            .padding()
            List(controller.looks.looks) { look in
                HStack(spacing: 16) {
                    PetSpriteView(character: look.character, state: PetState(), size: 64, isAnimationActive: false)
                    Text(look.name)
                    Spacer()
                    if controller.looks.selectedID == look.id {
                        Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else {
                        Button("Use") { perform("Look applied") { try controller.looks.select(look.id) } }
                    }
                    Menu {
                        Button("Preview Poses…") { previewing = look }
                        Button("Revise with Prompt…") { creating = PetLookCreationSession(base: look) }
                        Button("Export to Desktop") {
                            Task {
                                status = "Exporting pack…"
                                do {
                                    _ = try await controller.looks.exportPack(id: look.id)
                                    showStatus("Pack exported to Desktop")
                                } catch { status = nil; self.error = error.localizedDescription }
                            }
                        }
                        Button("Duplicate…") { duplicate(look) }
                        if !controller.looks.isBuiltin(look.id) {
                            Button("Edit…") { editing = look }
                            Button("Remove…", role: .destructive) { removing = look }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(look.name)")
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $creating) { session in
            PetLookCreationSheet(session: session, controller: controller) { showStatus("Look saved and applied") }
        }
        .sheet(item: $previewing) { look in
            NavigationStack {
                PetLookPreview(look: look).padding()
                    .navigationTitle(look.name)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { previewing = nil } } }
            }
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        }
        .sheet(item: $editing) { look in
            PetLookEditor(look: look) { updated in
                try controller.looks.save(updated)
                showStatus("Look saved and applied")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    status = "Importing look…"
                    do { try await controller.looks.importPack(at: url); showStatus("Look imported and applied") }
                    catch { status = nil; self.error = error.localizedDescription }
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .confirmationDialog("Remove this look?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { look in
            Button("Remove \(look.name)", role: .destructive) {
                perform("Look removed") { try controller.looks.remove(look.id) }
                removing = nil
            }
        } message: { _ in Text("If active, the pet returns to RxBuddy. Your conversation continues.") }
        .alert("Unable to Change Look", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .overlay { if let status { PetActionStatusOverlay(message: status).allowsHitTesting(false) } }
    }

    private func duplicate(_ look: PetLook) {
        var copy = look
        copy.id = UUID().uuidString
        copy.name = "\(look.name.prefix(65)) Copy"
        editing = copy
    }

    private func perform(_ message: String, action: () throws -> Void) {
        do { try action(); showStatus(message) }
        catch { self.error = error.localizedDescription }
    }

    private func showStatus(_ message: String) {
        status = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if status == message { status = nil }
        }
    }
}

private struct PetLookEditor: View {
    @State var look: PetLook
    let save: (PetLook) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PetLookPreview(look: look).frame(height: 270)
                        Spacer()
                    }
                }
                Section("Appearance") {
                    TextField("Name", text: $look.name)
                    LabeledContent("Hue", value: "\(Int(look.hue))°")
                    Slider(value: $look.hue, in: 0...360)
                    LabeledContent("Saturation", value: look.saturation.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $look.saturation, in: 0...2)
                    Picker("Accessory", selection: $look.accessory) {
                        ForEach(PetLook.accessories, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Edit Pet Look")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Use") {
                        do { try save(look); dismiss() } catch { self.error = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 440, idealWidth: 480, maxWidth: .infinity, minHeight: 540, idealHeight: 600, maxHeight: .infinity)
        .alert("Unable to Save Look", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
