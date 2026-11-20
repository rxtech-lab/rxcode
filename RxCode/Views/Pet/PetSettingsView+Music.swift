import AppKit
import MusicKit
import RxCodeCore
import SwiftUI

extension PetSettingsView {
    @ViewBuilder
    var musicSection: some View {
        let music = controller.music
        Section {
            HStack(spacing: 12) {
                Image(systemName: musicStatusSymbol)
                    .font(.title2)
                    .foregroundStyle(musicStatusTint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Music")
                    Text(musicStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                musicPrimaryAction
                Menu {
                    Button("Recheck Connection") { linkAppleMusic() }
                        .disabled(music.isBusy || music.isTurningOff)
                    Button("Open Music") { openMusicApp() }
                    Button("Privacy Settings…") { openMusicPrivacySettings() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Apple Music options")
            }
            .padding(.vertical, 4)
            if let error = music.errorMessage {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
        } header: {
            Text("Apple Music")
        } footer: {
            Text("Uses the Apple Music account signed in to Music on this Mac. Catalog playback needs an active subscription.")
        }
        Section {
            if music.enabled {
                LabeledContent {
                    Button("Stop", role: .destructive) {
                        Task { _ = await music.off() }
                    }
                    .disabled(music.isTurningOff)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(music.title).lineLimit(1)
                        if !music.artist.isEmpty {
                            Text(music.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pet Player")
        } footer: {
            Text("Ask the voice agent to play, pause, resume, or stop a song or artist.")
        }
    }

    /// One contextual call to action; everything else lives in the "…" menu.
    @ViewBuilder
    private var musicPrimaryAction: some View {
        let music = controller.music
        switch music.authorizationStatus {
        case .denied, .restricted:
            Button("Open Settings") { openMusicPrivacySettings() }
        case .authorized where music.isLinked && music.canPlayCatalogContent == false:
            Button("Open Music") { openMusicApp() }
        case .authorized where music.isLinked:
            EmptyView()
        case .authorized:
            Button("Retry Account Check") { music.refreshConnectionInBackground() }
                .disabled(music.isCheckingConnection)
        default:
            Button("Link") { linkAppleMusic() }
                .buttonStyle(.borderedProminent)
                .disabled(music.isBusy || music.isTurningOff)
        }
    }

    private var musicStatusSymbol: String {
        let music = controller.music
        switch music.authorizationStatus {
        case .denied, .restricted: return "xmark.circle.fill"
        case .authorized where music.isLinked:
            return music.canPlayCatalogContent == false ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
        default: return music.errorMessage == nil ? "music.note" : "exclamationmark.circle.fill"
        }
    }

    private var musicStatusTint: Color {
        switch musicStatusSymbol {
        case "checkmark.circle.fill": .green
        case "xmark.circle.fill": .red
        case "exclamationmark.circle.fill": .orange
        default: .secondary
        }
    }

    private var musicStatusDetail: String {
        let music = controller.music
        switch music.authorizationStatus {
        case .denied: return "Access denied in Privacy settings"
        case .restricted: return "Access restricted on this Mac"
        case .authorized where music.isLinked:
            return music.canPlayCatalogContent == false ? "Linked · Subscription required for playback" : "Linked · Ready to play"
        case .authorized:
            if music.isCheckingConnection { return "Authorized · Checking account…" }
            return music.connectionError ?? "Authorized · Account not verified"
        default: return "Not linked"
        }
    }

    private func linkAppleMusic() {
        Task {
            do {
                _ = try await controller.music.handle(.object(["action": .string("connect")]))
            } catch is CancellationError {
            } catch {
                controller.alertErrorMessage = error.localizedDescription
            }
        }
    }

    private func openMusicApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private func openMusicPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
            NSWorkspace.shared.open(url)
        }
    }
}
