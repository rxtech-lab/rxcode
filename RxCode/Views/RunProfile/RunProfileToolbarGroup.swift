import RxCodeCore
import SwiftUI

/// Single combined toolbar pill containing: profile picker · run button ·
/// stop button (the stop button is hidden entirely when no task is active).
/// Wrapped in its own subview so its body re-renders independently of the
/// rest of the toolbar.
struct RunProfileToolbarGroup: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    private var project: Project? { windowState.selectedProject }

    private var profiles: [RunProfile] {
        guard let project else { return [] }
        return appState.runProfiles(for: project.id)
    }

    private var selectedProfile: RunProfile? {
        guard let id = windowState.selectedRunProfileId else { return profiles.first }
        return profiles.first { $0.id == id } ?? profiles.first
    }

    private var activeTasks: [RunTask] {
        appState.runService.activeTasks
    }

    private var isSelectedProfileRunning: Bool {
        guard let selectedProfile, let project else { return false }
        return activeTasks.contains {
            $0.profile.id == selectedProfile.id && $0.project.id == project.id
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            profilePicker
                .padding(.leading, 4)

            Divider().frame(height: 14)

            runButton

            if !activeTasks.isEmpty {
                Divider().frame(height: 14)
                stopButton
            }
        }
        .task(id: project?.id) {
            if let project { await appState.ensureRunProfilesLoaded(for: project.id) }
        }
    }

    // MARK: - Profile picker

    private var profilePicker: some View {
        Menu {
            if profiles.isEmpty {
                Text("No profiles for this project")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profiles) { profile in
                    Button {
                        windowState.selectedRunProfileId = profile.id
                    } label: {
                        HStack {
                            Text(profile.name.prefix(150) + (profile.name.count > 150 ? "…" : ""))
                            if selectedProfile?.id == profile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
            }
            Button("Edit Configurations…") {
                windowState.showRunConfigurations = true
            }
            .disabled(project == nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 11))
                Text(selectedProfile?.name ?? "Run")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 200)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select Run Profile")
    }

    // MARK: - Run button

    private var runButton: some View {
        Button {
            guard let project, let profile = selectedProfile else { return }
            _ = appState.runService.start(profile: profile, project: project)
            openRunInspector()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .help(isSelectedProfileRunning
            ? "\(selectedProfile?.name ?? "") is already running"
            : "Run \(selectedProfile?.name ?? "")")
        .disabled(selectedProfile == nil || project == nil || isSelectedProfileRunning)
    }

    // MARK: - Stop button

    @ViewBuilder
    private var stopButton: some View {
        if activeTasks.count == 1, let only = activeTasks.first {
            Button {
                appState.runService.stop(taskId: only.id)
            } label: {
                stopIcon
            }
            .help("Stop \(only.profile.name)")
        } else {
            Menu {
                ForEach(activeTasks) { task in
                    Button {
                        appState.runService.stop(taskId: task.id)
                    } label: {
                        Text("Stop '\(task.profile.name)'")
                    }
                }
                Divider()
                Button("Stop All") {
                    appState.runService.stopAll()
                }
            } label: {
                stopIcon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Stop running tasks")
            .padding(.trailing, 4)
        }
    }

    private var stopIcon: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
            if activeTasks.count > 1 {
                Text("\(activeTasks.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(Capsule().fill(.red))
                    .offset(x: 6, y: -4)
            }
        }
        .contentShape(Rectangle())
    }

    private func openRunInspector() {
        windowState.inspectorMode = .inspector
        windowState.inspectorTab = .run
        windowState.showInspector = true
        windowState.selectedRunTaskId = appState.runService.activeTasks.first?.id
    }
}
