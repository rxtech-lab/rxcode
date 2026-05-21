import AppKit
import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Before / after steps

extension RunProfileDetailForm {
    @ViewBuilder
    func stepsSection(title: String, steps: Binding<[RunStep]>) -> some View {
        Section {
            if steps.wrappedValue.isEmpty {
                Text("There are no tasks to run \(title.lowercased()).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(steps.wrappedValue.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { steps.wrappedValue[i].type },
                            set: { steps.wrappedValue[i].type = $0 }
                        )) {
                            ForEach(RunStepType.allCases, id: \.self) { t in
                                Text(t.rawValue.capitalized).tag(t)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        TextField("command", text: Binding(
                            get: { steps.wrappedValue[i].command },
                            set: { steps.wrappedValue[i].command = $0 }
                        ))
                        .font(.system(.body, design: .monospaced))
                        Button {
                            if i > 0 { steps.wrappedValue.swapAt(i, i - 1) }
                        } label: { Image(systemName: "arrow.up") }
                            .disabled(i == 0)
                        Button {
                            if i < steps.wrappedValue.count - 1 { steps.wrappedValue.swapAt(i, i + 1) }
                        } label: { Image(systemName: "arrow.down") }
                            .disabled(i == steps.wrappedValue.count - 1)
                        Button {
                            steps.wrappedValue.remove(at: i)
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Menu {
                    Button("Bash") {
                        steps.wrappedValue.append(RunStep(type: .bash, command: ""))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    // MARK: - File pickers

    func pickDirectory(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        if panel.runModal() == .OK, let url = panel.url {
            onPick(displayPath(for: url))
        }
    }

    func pickFile(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        if panel.runModal() == .OK, let url = panel.url {
            onPick(displayPath(for: url))
        }
    }

    /// If the picked URL is inside the project root, return a project-relative
    /// path; otherwise return the absolute path.
    func displayPath(for url: URL) -> String {
        let absolute = url.path
        let root = (project.path as NSString).standardizingPath
        let std = (absolute as NSString).standardizingPath
        if std.hasPrefix(root + "/") {
            return "./" + String(std.dropFirst(root.count + 1))
        }
        return std
    }
}
