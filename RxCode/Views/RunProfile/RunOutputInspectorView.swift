import AppKit
import RxCodeCore
import SwiftTerm
import SwiftUI

/// Inspector body for the "Run" tab. Header row holds the task dropdown plus
/// per-task action icons; the body re-parents the selected task's
/// `LocalProcessTerminalView` so output keeps buffering when hidden.
struct RunOutputInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private var tasks: [RunTask] { appState.runService.tasks }

    private var selectedTask: RunTask? {
        if let id = windowState.selectedRunTaskId, let match = tasks.first(where: { $0.id == id }) {
            return match
        }
        return tasks.first
    }

    var body: some View {
        VStack(spacing: 0) {
            taskBar
            Divider()
            if let task = selectedTask {
                RunTaskTerminalHost(view: task.terminalView)
                    .padding(8)
                    .background(ClaudeTheme.codeBackground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .onAppear {
            if windowState.selectedRunTaskId == nil {
                windowState.selectedRunTaskId = tasks.first?.id
            }
        }
        .onChange(of: tasks.map(\.id)) { _, newIds in
            // If the currently-selected task was removed, reselect the newest.
            if let id = windowState.selectedRunTaskId, !newIds.contains(id) {
                windowState.selectedRunTaskId = newIds.first
            } else if windowState.selectedRunTaskId == nil {
                windowState.selectedRunTaskId = newIds.first
            }
        }
    }

    private var taskBar: some View {
        HStack(spacing: 8) {
            Menu {
                if tasks.isEmpty {
                    Text("No tasks").foregroundStyle(.secondary)
                } else {
                    ForEach(tasks) { task in
                        Button {
                            windowState.selectedRunTaskId = task.id
                        } label: {
                            HStack {
                                statusDot(for: task.status)
                                Text("\(task.profile.name) · \(task.status.label)")
                                if selectedTask?.id == task.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if let task = selectedTask {
                        statusDot(for: task.status)
                        Text("\(task.profile.name) · \(task.status.label)")
                            .lineLimit(1)
                    } else {
                        Text("No tasks")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if let task = selectedTask {
                if !task.status.isTerminal {
                    Button {
                        appState.runService.stop(taskId: task.id)
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop \(task.profile.name)")
                } else {
                    Button {
                        _ = appState.runService.start(profile: task.profile, project: task.project)
                        windowState.selectedRunTaskId = appState.runService.tasks.first?.id
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-run \(task.profile.name)")

                    Button {
                        appState.runService.remove(taskId: task.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear task")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClaudeTheme.surfaceElevated)
    }

    private func statusDot(for status: RunTaskStatus) -> some View {
        let color: SwiftUI.Color = {
            switch status {
            case .running: return ClaudeTheme.statusWarning
            case .succeeded: return ClaudeTheme.statusSuccess
            case .failed, .signaled: return ClaudeTheme.statusError
            case .stopped: return SwiftUI.Color.secondary
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "play.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No active runs")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Pick a profile in the toolbar and press Run.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
