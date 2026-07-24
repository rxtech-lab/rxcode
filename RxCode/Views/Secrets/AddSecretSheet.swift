import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Adds one or more encrypted secret files to an environment from three
/// sources: a detected local `.env`, a picked file, or manually entered values.
struct AddSecretSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let repoIdentifier: String
    let envId: String
    let environmentKey: SecretsEnvironmentKey
    var projectPath: String?
    var existingFilenames: Set<String>
    var onSaved: () -> Void

    enum Source: String, CaseIterable, Identifiable {
        case detected = "Detected"
        case file = "File"
        case manual = "Manual"
        var id: String { rawValue }
    }

    @State private var source: Source = .manual
    @State private var detected: [DetectedEnv] = []
    @State private var selectedDetected: Set<String> = []
    @State private var pickedFilename = ""
    @State private var pickedContent = ""
    @State private var manualFilename = ".env"
    @State private var manualRows: [ManualRow] = [ManualRow()]

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Secret").font(.headline)

            Picker("Source", selection: $source) {
                ForEach(availableSources) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch source {
                case .detected: detectedView
                case .file: fileView
                case .manual: manualView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Encrypt & Upload") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !canSave)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .onAppear {
            detected = DetectedEnv.scan(directory: projectPath)
            selectedDetected = Set(detected.map(\.filename))
            source = detected.isEmpty ? .manual : .detected
        }
    }

    private var availableSources: [Source] {
        detected.isEmpty ? [.file, .manual] : Source.allCases
    }

    // MARK: - Detected

    @ViewBuilder private var detectedView: some View {
        if detected.isEmpty {
            Text("No .env files found in the project folder.")
                .foregroundStyle(.secondary)
        } else {
            List {
                ForEach(detected) { env in
                    Toggle(isOn: Binding(
                        get: { selectedDetected.contains(env.filename) },
                        set: { on in
                            if on { selectedDetected.insert(env.filename) }
                            else { selectedDetected.remove(env.filename) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(env.filename)
                                if existingFilenames.contains(env.filename) {
                                    Text("overwrites").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text("\(env.byteCount) bytes").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - File picker

    @ViewBuilder private var fileView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                pickFile()
            } label: {
                Label(pickedFilename.isEmpty ? "Choose File…" : pickedFilename, systemImage: "folder")
            }
            if !pickedContent.isEmpty {
                Text("\(pickedContent.utf8.count) bytes").font(.caption).foregroundStyle(.secondary)
                if existingFilenames.contains(pickedFilename) {
                    Text("Will overwrite the existing \(pickedFilename).")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextEditor(text: $pickedContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
            }
        }
    }

    /// Opens an `NSOpenPanel` instead of SwiftUI's `.fileImporter` so hidden
    /// dotfiles like `.env` are selectable (`.fileImporter` cannot show them).
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.data, .text, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? Data(contentsOf: url) {
            // Prefer the path relative to the project root so files with the same
            // base name in different folders don't collide on upload; fall back
            // to the bare name for files chosen outside the project.
            if let projectPath {
                let root = URL(fileURLWithPath: projectPath, isDirectory: true)
                pickedFilename = DetectedEnv.relativePath(of: url, under: root) ?? url.lastPathComponent
            } else {
                pickedFilename = url.lastPathComponent
            }
            pickedContent = String(decoding: data, as: UTF8.self)
        } else {
            errorMessage = "Couldn't read the selected file."
        }
    }

    // MARK: - Manual

    @ViewBuilder private var manualView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filename").foregroundStyle(.secondary)
                TextField(".env", text: $manualFilename).textFieldStyle(.roundedBorder)
            }
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($manualRows) { $row in
                        HStack(spacing: 6) {
                            TextField("KEY", text: $row.key).textFieldStyle(.roundedBorder)
                            Text("=").foregroundStyle(.secondary)
                            TextField("value", text: $row.value).textFieldStyle(.roundedBorder)
                            Button {
                                manualRows.removeAll { $0.id == row.id }
                                if manualRows.isEmpty { manualRows = [ManualRow()] }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button { manualRows.append(ManualRow()) } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Save

    private var canSave: Bool {
        switch source {
        case .detected: return !selectedDetected.isEmpty
        case .file: return !pickedFilename.isEmpty && !pickedContent.isEmpty
        case .manual:
            return !manualFilename.trimmingCharacters(in: .whitespaces).isEmpty
                && manualRows.contains { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    /// The `(filename, content)` pairs to upload for the current source.
    private func pendingUploads() -> [(filename: String, content: String)] {
        switch source {
        case .detected:
            return detected
                .filter { selectedDetected.contains($0.filename) }
                .map { ($0.filename, $0.content) }
        case .file:
            return [(pickedFilename, pickedContent)]
        case .manual:
            let content = manualRows
                .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "\($0.key.trimmingCharacters(in: .whitespaces))=\($0.value)" }
                .joined(separator: "\n") + "\n"
            return [(manualFilename.trimmingCharacters(in: .whitespaces), content)]
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            for upload in pendingUploads() {
                // Manual filenames are free-form; picker/detected paths are
                // project-relative. Both must normalize to a safe relative path.
                guard let filename = SecretsFilePath.sanitize(upload.filename) else {
                    errorMessage = "“\(upload.filename)” isn’t a valid file path. Use a relative path without “..”."
                    return
                }
                let body = try await appState.encryptSecretFile(
                    forEnvironmentKey: environmentKey,
                    filename: filename,
                    content: upload.content
                )
                _ = try await appState.secrets.upsertFile(repo: repoIdentifier, envId: envId, body: body)
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Supporting types

private struct ManualRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}

struct DetectedEnv: Identifiable {
    /// Repo-relative path (e.g. "frontend/.env"), so files with the same base
    /// name in different folders stay distinct.
    let filename: String
    let content: String
    var id: String { filename }
    var byteCount: Int { content.utf8.count }

    /// Directories skipped while recursing — noise that never holds real secrets.
    private static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", ".next", "Pods",
    ]

    /// Recursively scans `directory` for files whose name starts with `.env`,
    /// keying each hit by its path relative to `directory`. Uses path-based
    /// listing because `.env` is a hidden dotfile.
    static func scan(directory: String?) -> [DetectedEnv] {
        guard let directory else { return [] }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        var results: [DetectedEnv] = []
        scan(directory: root, root: root, into: &results)
        return results.sorted { $0.filename < $1.filename }
    }

    private static func scan(directory: URL, root: URL, into results: inout [DetectedEnv]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if ignoredDirectories.contains(entry.lastPathComponent) { continue }
                scan(directory: entry, root: root, into: &results)
            } else {
                let name = entry.lastPathComponent
                guard name == ".env" || name.hasPrefix(".env") else { continue }
                guard let data = fm.contents(atPath: entry.path) else { continue }
                let relative = Self.relativePath(of: entry, under: root) ?? name
                results.append(DetectedEnv(filename: relative, content: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Path of `url` relative to `root`, or nil if `url` isn't inside `root`.
    static func relativePath(of url: URL, under root: URL) -> String? {
        let target = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard target.count > base.count, Array(target.prefix(base.count)) == base else { return nil }
        return target.dropFirst(base.count).joined(separator: "/")
    }
}
