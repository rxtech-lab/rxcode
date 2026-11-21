import AppKit
import RxCodeCore
import SwiftTerm
import SwiftUI

/// Inspector body for the "Run" tab. A tab row lists run tasks with per-task
/// actions; the body re-parents the selected task's `LocalProcessTerminalView`
/// so output keeps buffering when hidden.
struct RunOutputInspectorView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTaskID: UUID?
    let showsLiveTerminal: Bool
    @State private var draggingTaskID: UUID?

    private var runService: RunService { appState.runService }
    private var tasks: [RunTask] { runService.tasks }

    private var selectedTask: RunTask? {
        if let id = selectedTaskID, let match = tasks.first(where: { $0.id == id }) {
            return match
        }
        return tasks.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let task = selectedTask {
                taskBar(selected: task)
                Group {
                    if showsLiveTerminal {
                        RunTaskTerminalHost(view: task.terminalView)
                    } else {
                        ScrollView {
                            Text(verbatim: task.terminalOutputTail)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                    }
                }
                .padding(8)
                .background(ClaudeTheme.codeBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Active Runs",
                    systemImage: "play.rectangle",
                    description: Text("Pick a profile in the toolbar and press Run.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: tasks.map(\.id), initial: true) { _, ids in
            if selectedTaskID != selectedTask?.id { selectedTaskID = selectedTask?.id }
            if let draggingTaskID, !ids.contains(draggingTaskID) { self.draggingTaskID = nil }
        }
    }

    private func taskBar(selected: RunTask) -> some View {
        HStack(spacing: 2) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(tasks) { task in
                            RunTaskTab(
                                title: runService.displayName(for: task),
                                status: task.status,
                                isActive: task.id == selected.id,
                                onSelect: { selectedTaskID = task.id },
                                onStop: { runService.stop(taskId: task.id) },
                                onRerun: { rerun(task) },
                                onClear: { runService.remove(taskId: task.id) },
                                onClearFinished: { runService.clearFinished() }
                            )
                            .workspaceReorderableTab(id: task.id, draggingID: $draggingTaskID) { dragged, target in
                                runService.move(taskId: dragged, to: target)
                            }
                            .id(task.id)
                        }
                    }
                    .frame(height: 30)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .workspaceTabStripDropArea(draggingID: $draggingTaskID) { dragged, target in
                    runService.move(taskId: dragged, to: target)
                }
                .onChange(of: selected.id, initial: true) { _, id in
                    withAnimation(.smooth(duration: 0.2)) { reader.scrollTo(id) }
                }
            }

            let name = runService.displayName(for: selected)
            if selected.status.isTerminal {
                WorkspaceTabStripButton(systemImage: "arrow.clockwise", help: "Re-run \(name)") { rerun(selected) }
            } else {
                WorkspaceTabStripButton(systemImage: "stop.fill", help: "Stop \(name)") {
                    runService.stop(taskId: selected.id)
                }
            }
        }
        .padding(.horizontal, 8)
        .background(ClaudeTheme.codeBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ClaudeTheme.divider)
                .frame(height: 0.5)
        }
    }

    private func rerun(_ task: RunTask) {
        selectedTaskID = runService.start(profile: task.profile, project: task.project).id
    }
}

/// A run task tab: status dot, name, and a close button once the run has finished.
private struct RunTaskTab: View {
    let title: String
    let status: RunTaskStatus
    let isActive: Bool
    let onSelect: () -> Void
    let onStop: () -> Void
    let onRerun: () -> Void
    let onClear: () -> Void
    let onClearFinished: () -> Void
    @State private var isHovered = false

    private var statusColor: SwiftUI.Color {
        switch status {
        case .running: ClaudeTheme.statusWarning
        case .succeeded: ClaudeTheme.statusSuccess
        case .failed, .signaled: ClaudeTheme.statusError
        case .stopped: ClaudeTheme.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .overlay {
                    if status == .running {
                        Circle().stroke(statusColor.opacity(0.35), lineWidth: 3)
                    }
                }
                .help(status.label)
            Text(title)
                .font(.system(size: ClaudeTheme.size(11), weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive || isHovered ? ClaudeTheme.textPrimary : ClaudeTheme.textSecondary)
                .lineLimit(1)
            WorkspaceTabCloseButton(isVisible: status.isTerminal && (isHovered || isActive),
                                    help: "Clear task", action: onClear)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .workspaceUnderlineTab(selected: isActive, hovered: isHovered)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            if status.isTerminal {
                Button("Re-run", systemImage: "arrow.clockwise", action: onRerun)
                Divider()
                Button("Clear Task", systemImage: "xmark", action: onClear)
            } else {
                Button("Stop", systemImage: "stop.fill", action: onStop)
            }
            Button("Clear Finished Tasks", action: onClearFinished)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status.label)")
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }
}

/// Wraps an externally-owned `LocalProcessTerminalView` so SwiftUI can host
/// it without taking ownership. SwiftUI reuses the same container across
/// selection changes, so the container must be re-pointed at exactly one
/// terminal: adding the new view without detaching the previous one leaves
/// both stacked, and the stale view wins on the way back.
struct RunTaskTerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        install(in: nsView)
    }

    /// Makes `view` the container's only subview. No-ops when it already is,
    /// so a plain re-layout doesn't steal first responder.
    private func install(in container: NSView) {
        let alreadyInstalled = view.superview === container && container.subviews.count == 1
        guard !alreadyInstalled else { return }

        for stale in container.subviews where stale !== view {
            stale.removeFromSuperview()
        }
        if view.superview !== container {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(view)
        }
    }
}
