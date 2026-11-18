import RxCodeChatKit
import RxCodeCore
import SwiftUI

// MARK: - App Scene, Settings Section, Window Presenter & Menu Commands

struct PetCompanionScene: Scene {
    let appState: AppState
    let workspaceManager: WorkspaceManager

    var body: some Scene {
        Window("Pet Companion", id: PetWindows.companionID) {
            PetCompanionView(controller: .shared)
                .environment(appState)
                .environment(workspaceManager)
                .modifier(DownloadWindowPresenter())
        }
        .commandsRemoved()
        .defaultSize(width: 700, height: 660)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Pet & Voice Settings", id: PetWindows.settingsID) {
            PetSettingsView(controller: .shared)
                .environment(appState)
                .environment(workspaceManager)
                .modifier(DownloadWindowPresenter())
        }
        .commandsRemoved()
        .defaultSize(width: 780, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

struct PetSettingsSection: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var petController = PetController.shared
        VStack(alignment: .leading, spacing: 12) {
            Text("Desktop Pet & Voice Companion")
                .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

            Toggle(isOn: $petController.configuration.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Desktop Pet across Spaces")
                        .font(.system(size: ClaudeTheme.size(13)))
                    Text("Displays RxBuddy on your desktop with Codex Realtime and local speech + custom agent voice modes, proactive alerts, and daily workspace reports.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                Button("Configure Pet & Voice…") {
                    petController.openWindowAction = { id in openWindow(id: id) }
                    petController.openSettingsWindow()
                }

                Button("Voices…") {
                    petController.openWindowAction = { id in openWindow(id: id) }
                    petController.openSettingsWindow(tab: .voices)
                }

                Button("Open Companion") {
                    petController.openCompanionWindow()
                }
            }
        }
    }
}

struct PetWindowPresenter: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let workspaceManager: WorkspaceManager

    func body(content: Content) -> some View {
        content
            .onAppear {
                PetController.shared.bind(to: workspaceManager)
                PetController.shared.openWindowAction = { id in
                    openWindow(id: id)
                }
            }
    }
}

struct PetCommands: Commands {
    @Bindable var controller: PetController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Pet") {
            Button(controller.configuration.isEnabled ? "Hide Desktop Pet" : "Show Desktop Pet") {
                controller.setPetEnabled(!controller.configuration.isEnabled)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button(controller.isVoiceActive ? "Stop Voice Mode" : "Start Voice Mode") {
                controller.openWindowAction = { id in openWindow(id: id) }
                controller.toggleVoice()
            }
            .keyboardShortcut("v", modifiers: [.command, .option])

            Button(controller.isMuted ? "Unmute Microphone" : "Mute Microphone") {
                controller.toggleMute()
            }

            Divider()

            Button("Open Pet Companion") {
                controller.openWindowAction = { id in openWindow(id: id) }
                controller.openCompanionWindow()
            }

            Button("Daily Workspace Report…") {
                controller.openWindowAction = { id in openWindow(id: id) }
                Task {
                    await controller.triggerDailyReport(speakAloud: true, openSheet: true)
                }
            }

            Divider()

            Button("Manage Voices…") {
                controller.openWindowAction = { id in openWindow(id: id) }
                controller.openSettingsWindow(tab: .voices)
            }

            Button("Pet & Voice Settings…") {
                controller.openWindowAction = { id in openWindow(id: id) }
                controller.openSettingsWindow()
            }
        }
    }
}
