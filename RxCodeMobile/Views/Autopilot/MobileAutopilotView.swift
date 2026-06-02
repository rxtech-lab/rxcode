import RxCodeCore
import RxCodeSync
import SwiftUI

/// Mobile mirror of the desktop "Autopilot" settings tab. Every action is
/// performed by the paired Mac over the sync channel, so the screen requires an
/// online desktop; when offline it shows a notice and disables navigation.
struct MobileAutopilotView: View {
    @EnvironmentObject private var state: MobileAppState

    @State private var account: AutopilotAccountStatus?
    @State private var isLoading = true
    @State private var loadError: String?

    private var isOnline: Bool {
        state.isPaired && state.connectionState == .connected
    }

    var body: some View {
        Form {
            if !isOnline {
                offlineSection
            }

            accountSection

            if account?.isSignedIn == true {
                Section {
                    NavigationLink {
                        MobileAutomationView()
                    } label: {
                        Label("Automation", systemImage: "wand.and.stars")
                    }
                    NavigationLink {
                        MobileRepoSetupView()
                    } label: {
                        Label("Repo Setup", systemImage: "slider.horizontal.3")
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("Control what autopilot does automatically and the templates applied to new repositories.")
                }

                Section {
                    NavigationLink {
                        MobileSecretsView()
                    } label: {
                        Label("Secrets", systemImage: "key.fill")
                    }
                    NavigationLink {
                        MobileCIUpdatesView()
                    } label: {
                        Label("CI Auto-Update", systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink {
                        MobileDocsView()
                    } label: {
                        Label("Documentation", systemImage: "books.vertical.fill")
                    }
                    NavigationLink {
                        MobileReleaseView()
                    } label: {
                        Label("Releases", systemImage: "tag.fill")
                    }
                } header: {
                    Text("Repositories")
                } footer: {
                    Text("Manage end-to-end encrypted secrets, CI auto-update scans, indexed docs, and release workflows.")
                }
            } else if !isLoading, loadError == nil, isOnline {
                Section {
                    Text("Sign in with rxlab on your Mac to enable Autopilot.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Autopilot")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!isOnline)
        .mobileAutopilotLoadingOverlay(isOnline && isLoading && account == nil)
        .refreshable { await load() }
        .task { await load() }
    }

    private var offlineSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac offline")
                    Text("Connect to an online Mac to manage Autopilot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "wifi.slash").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking account…").foregroundStyle(.secondary)
                }
            } else if let account, account.isSignedIn {
                HStack(spacing: 12) {
                    avatar(account.avatarURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name ?? "rxlab account").font(.body)
                        if let email = account.email {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func avatar(_ urlString: String?) -> some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
    }

    private func load() async {
        guard isOnline else { isLoading = false; return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            account = try await state.loadAutopilotAccount()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
