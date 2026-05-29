import AppKit
import RxCodeCore
import SwiftUI

/// Detail form for a single hook. Mirrors `RunProfileDetailForm` but is
/// bash-only and adds an enabled toggle + trigger picker. Reuses
/// `BashEnvironmentEditor` for environment presets.
struct HookProfileDetailForm: View {
    @Binding var hook: HookProfile
    let project: Project

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $hook.name)
                Toggle("Enabled", isOn: $hook.enabled)
                Picker("Trigger", selection: $hook.trigger) {
                    ForEach(HookTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text(triggerHelp)
            }

            Section {
                HookLifecycleDiagram(trigger: hook.trigger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } header: {
                Text("Lifecycle")
            }

            Section {
                TextEditor(text: $hook.bash.command)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
                    )
                HStack {
                    TextField("Working Directory", text: $hook.bash.workingDirectory, prompt: Text(project.path))
                    Button("Browse…") {
                        pickDirectory { picked in
                            hook.bash.workingDirectory = picked
                        }
                    }
                    Button {
                        hook.bash.workingDirectory = ""
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .help("Reset to project root")
                }
            } header: {
                Text("Command")
            } footer: {
                Text("Runs with `/bin/zsh -lc`. Absolute or project-relative working directory; leave empty to use the project root.")
            }

            BashEnvironmentEditor(bash: $hook.bash, projectPath: project.path)
        }
        .formStyle(.grouped)
    }

    private var triggerHelp: String {
        switch hook.trigger {
        case .beforeSessionStart:
            return "Runs once when a new thread starts. Its output is added to the agent's context for that turn."
        case .beforeSessionStop:
            return "Runs when streaming stops. Its output is shown and saved with the thread. If the command exits non-zero, its output is sent back to the agent to continue (up to 3 times)."
        case .afterSessionStop:
            return "Runs after streaming stops. Its output is shown only — nothing is passed back to the session."
        }
    }

    // MARK: - Directory picker

    private func pickDirectory(onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = (project.path as NSString).standardizingPath
        let std = (url.path as NSString).standardizingPath
        if std.hasPrefix(root + "/") {
            onPick(String(std.dropFirst(root.count + 1)))
        } else if std == root {
            onPick("")
        } else {
            onPick(std)
        }
    }
}

// MARK: - Lifecycle diagram

/// A compact top-to-bottom flow that shows where the selected trigger fires in
/// the turn lifecycle. The hook node is accent-highlighted; the stop trigger
/// also shows its pass/fail branch (fail re-runs the agent).
private struct HookLifecycleDiagram: View {
    let trigger: HookTrigger

    var body: some View {
        VStack(spacing: 8) {
            switch trigger {
            case .beforeSessionStart:
                node("New thread starts", icon: "person.fill", role: .agent)
                connector("output added to context")
                node("Hook runs", icon: "bolt.fill", role: .hook)
                connector()
                node("Assistant reply", icon: "sparkles", role: .agent)

            case .beforeSessionStop:
                node("Assistant reply", icon: "sparkles", role: .agent)
                connector("streaming stops")
                node("Hook runs", icon: "bolt.fill", role: .hook)
                connector()
                HStack(alignment: .top, spacing: 12) {
                    node("Exit 0 → done", icon: "checkmark.circle.fill", role: .success)
                    node("Non-zero → agent continues", icon: "arrow.triangle.2.circlepath", role: .failure)
                }
                Text("On failure the hook output is sent back to the agent, which keeps fixing until the hook passes (max 3 retries).")
                    .font(.system(size: 10))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)

            case .afterSessionStop:
                node("Assistant reply", icon: "sparkles", role: .agent)
                connector("streaming stops")
                node("Thread saved", icon: "tray.and.arrow.down.fill", role: .neutral)
                connector()
                node("Hook runs", icon: "bolt.fill", role: .hook)
                Text("Shown only — nothing is passed back to the session.")
                    .font(.system(size: 10))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ClaudeTheme.borderSubtle, lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.2), value: trigger)
    }

    // MARK: Node

    private enum NodeRole {
        case agent, hook, neutral, success, failure
    }

    @ViewBuilder
    private func node(_ title: String, icon: String, role: NodeRole) -> some View {
        let isHook = role == .hook
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: isHook ? .semibold : .regular))
        }
        .foregroundStyle(foreground(for: role))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(background(for: role), in: Capsule())
        .overlay(
            Capsule().strokeBorder(border(for: role), lineWidth: isHook ? 0 : 0.75)
        )
    }

    @ViewBuilder
    private func connector(_ label: String? = nil) -> some View {
        VStack(spacing: 1) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ClaudeTheme.textTertiary)
            if let label {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
    }

    // MARK: Styling

    private func foreground(for role: NodeRole) -> Color {
        switch role {
        case .hook: return ClaudeTheme.textOnAccent
        case .success: return .green
        case .failure: return .orange
        case .agent, .neutral: return ClaudeTheme.textSecondary
        }
    }

    private func background(for role: NodeRole) -> Color {
        switch role {
        case .hook: return ClaudeTheme.accent
        case .success: return Color.green.opacity(0.12)
        case .failure: return Color.orange.opacity(0.12)
        case .agent: return ClaudeTheme.surfaceTertiary
        case .neutral: return ClaudeTheme.surfacePrimary
        }
    }

    private func border(for role: NodeRole) -> Color {
        switch role {
        case .hook: return .clear
        case .success: return Color.green.opacity(0.4)
        case .failure: return Color.orange.opacity(0.4)
        case .agent, .neutral: return ClaudeTheme.border
        }
    }
}
