import AppKit
import RxCodeCore
import SwiftUI

/// Detail form for a single hook. Mirrors `RunProfileDetailForm` but is
/// bash-only and adds an enabled toggle + trigger picker. Reuses
/// `BashEnvironmentEditor` for environment presets.
struct HookProfileDetailForm: View {
    @Environment(AppState.self) private var appState
    @Binding var hook: HookProfile
    let project: Project

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $hook.name)
                Toggle("Enabled", isOn: $hook.enabled)
                Picker("Action", selection: $hook.action) {
                    ForEach(HookAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .onChange(of: hook.action) { _, newAction in
                    // Built-in actions only run at a fixed lifecycle.
                    if let fixed = newAction.fixedTrigger { hook.trigger = fixed }
                    if newAction == .codeReview, hook.codeReview == nil {
                        hook.codeReview = CodeReviewConfig()
                    }
                }
                Picker("Trigger", selection: $hook.trigger) {
                    ForEach(HookTrigger.allCases, id: \.self) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
                .disabled(hook.action.fixedTrigger != nil)
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

            switch hook.action {
            case .command:
                ProfileCommandSections(
                    profileID: hook.id,
                    project: project,
                    type: $hook.type,
                    bash: $hook.bash,
                    xcode: $hook.xcode,
                    make: $hook.make,
                    package: $hook.package
                )
                BashEnvironmentEditor(bash: $hook.bash, projectPath: project.path)
            case .codeReview:
                codeReviewSection
            case .commitPush:
                commitPushSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Built-in action sections

    private var codeReviewSection: some View {
        Section {
            Picker("Review model", selection: codeReviewModelBinding) {
                Text("Same as thread").tag("")
                ForEach(appState.availableAgentModelSections(), id: \.id) { section in
                    Section(section.title) {
                        ForEach(section.models, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Extra instructions (optional)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextEditor(text: codeReviewInstructionsBinding)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 70)
            }
        } header: {
            Text("Code Review")
        } footer: {
            Text("After the session is finalized, the change is sent to a linked [Code Review] thread that runs no hooks. If the review requests changes, its notes are sent back into this thread so the agent keeps fixing and is re-reviewed (up to 3 times).")
        }
    }

    private var commitPushSection: some View {
        Section {
            Text("After a successful session, the agent is asked to commit the changed files and push them (choosing a new or existing branch). The commit turn itself won't re-trigger this hook. If a Code Review hook is also enabled, the commit only happens after the review passes.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } header: {
            Text("Commit & Push")
        }
    }

    private var codeReviewModelBinding: Binding<String> {
        Binding(
            get: { hook.codeReview?.model ?? "" },
            set: { newValue in
                var cfg = hook.codeReview ?? CodeReviewConfig()
                cfg.model = newValue.isEmpty ? nil : newValue
                hook.codeReview = cfg
            }
        )
    }

    private var codeReviewInstructionsBinding: Binding<String> {
        Binding(
            get: { hook.codeReview?.instructions ?? "" },
            set: { newValue in
                var cfg = hook.codeReview ?? CodeReviewConfig()
                cfg.instructions = newValue.isEmpty ? nil : newValue
                hook.codeReview = cfg
            }
        )
    }

    private var triggerHelp: String {
        switch hook.action {
        case .codeReview:
            return "Code Review runs after the session is finalized; a failing review sends the agent back to work and re-reviews."
        case .commitPush:
            return "Commit & Push runs after the session is finalized and saved."
        case .command:
            switch hook.trigger {
            case .beforeSessionStart:
                return "Runs once when a new thread starts. Its output is added to the agent's context for that turn."
            case .beforeSessionStop:
                return "Runs when streaming stops. Its output is shown and saved with the thread. If the command exits non-zero, its output is sent back to the agent to continue (up to 3 times)."
            case .afterSessionStop:
                return "Runs after streaming stops. Its output is shown only — nothing is passed back to the session."
            }
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
