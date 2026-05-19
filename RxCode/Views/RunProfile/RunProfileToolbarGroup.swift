import RxCodeCore
import SwiftUI

/// Single combined toolbar pill containing: profile picker · (optional)
/// destination picker · run button · stop button (the stop button is hidden
/// entirely when no task is active). Wrapped in its own subview so its body
/// re-renders independently of the rest of the toolbar.
struct RunProfileToolbarGroup: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState

    /// Destinations cached per (container, scheme). Loaded on demand when
    /// the picker first appears or the refresh button is tapped.
    @State private var destinations: [XcodeDestination] = []
    @State private var isLoadingDestinations = false
    @State private var lastLoadedKey: String?

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

    /// Stable key for the destination cache lookup. Changes when the user
    /// switches profile or edits the container/scheme.
    private var destinationCacheKey: String? {
        guard let profile = selectedProfile,
              profile.type == .xcode,
              let xcode = profile.xcode,
              !xcode.container.isEmpty,
              !xcode.scheme.isEmpty else { return nil }
        return "\(xcode.container)::\(xcode.scheme)"
    }

    var body: some View {
        HStack(spacing: 2) {
            profilePicker
                .padding(.leading, 4)

            if shouldShowDestinationPicker {
                Divider().frame(height: 14)
                destinationPicker
            }

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
        .task(id: destinationCacheKey) {
            await loadDestinationsIfNeeded(force: false)
        }
    }

    private var shouldShowDestinationPicker: Bool {
        guard let profile = selectedProfile else { return false }
        return profile.type == .xcode && profile.xcode != nil
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
        .accessibilityIdentifier("run-profile-menu")
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
        .accessibilityIdentifier("run-profile-run-button")
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
            .accessibilityIdentifier("run-profile-stop-button")
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
            .accessibilityIdentifier("run-profile-stop-menu")
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

    // MARK: - Destination picker

    private var destinationPicker: some View {
        Menu {
            if isLoadingDestinations && destinations.isEmpty {
                Text("Loading destinations…").foregroundStyle(.secondary)
            } else if destinations.isEmpty {
                Text("No destinations found").foregroundStyle(.secondary)
                Text("Check the scheme and container path.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            } else {
                let grouped = Dictionary(grouping: destinations, by: { $0.groupLabel })
                let order = ["macOS", "Mac Catalyst", "iOS Simulators", "iOS Devices",
                             "tvOS Simulators", "tvOS Devices",
                             "watchOS Simulators", "watchOS Devices",
                             "visionOS Simulators", "visionOS Devices", "Other"]
                let presentGroups = order.filter { grouped[$0] != nil }
                ForEach(presentGroups, id: \.self) { group in
                    Section(group) {
                        ForEach(grouped[group] ?? []) { destination in
                            Button {
                                selectDestination(destination)
                            } label: {
                                HStack {
                                    Text(destination.displayName)
                                    if destination.id == currentDestination?.id {
                                        Image(systemName: "checkmark")
                                    }
                                    if !destination.isLaunchable {
                                        Text("(build only)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                Task { await loadDestinationsIfNeeded(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: destinationIconName)
                    .font(.system(size: 11))
                Text(currentDestination?.displayName ?? "Any Mac")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 220)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select Run Destination")
        .accessibilityIdentifier("run-profile-destination-menu")
    }

    private var currentDestination: XcodeDestination? {
        selectedProfile?.xcode?.selectedDestination
    }

    private var destinationIconName: String {
        switch currentDestination?.kind {
        case .iosSimulator, .iosDevice: return "iphone"
        case .tvSimulator, .tvDevice: return "tv"
        case .watchSimulator, .watchDevice: return "applewatch"
        case .visionSimulator, .visionDevice: return "visionpro"
        case .macCatalyst: return "ipad.and.iphone"
        case .macOS, .other, nil: return "desktopcomputer"
        }
    }

    private func selectDestination(_ destination: XcodeDestination) {
        guard let project, let profile = selectedProfile, profile.type == .xcode else { return }
        var updated = profiles
        guard let idx = updated.firstIndex(where: { $0.id == profile.id }) else { return }
        var newProfile = updated[idx]
        var xcode = newProfile.xcode ?? XcodeRunConfig()
        xcode.selectedDestination = destination
        // Clear the legacy free-text override so it doesn't shadow the new
        // structured selection on the next run.
        xcode.destination = ""
        newProfile.xcode = xcode
        newProfile.updatedAt = Date()
        updated[idx] = newProfile
        appState.setRunProfiles(updated, for: project.id)
    }

    private func loadDestinationsIfNeeded(force: Bool) async {
        guard let key = destinationCacheKey,
              let project,
              let xcode = selectedProfile?.xcode else {
            destinations = []
            return
        }
        if !force && lastLoadedKey == key && !destinations.isEmpty { return }

        isLoadingDestinations = true
        defer { isLoadingDestinations = false }

        let loaded = await XcodeDestinationService.shared.destinations(
            projectPath: project.path,
            container: xcode.container,
            isWorkspace: xcode.isWorkspace,
            scheme: xcode.scheme,
            forceRefresh: force
        )
        // Guard against late returns after the user switched profiles.
        if destinationCacheKey == key {
            destinations = loaded
            lastLoadedKey = key
        }
    }
}
