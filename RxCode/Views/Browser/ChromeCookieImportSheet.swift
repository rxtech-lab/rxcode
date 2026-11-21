import RxCodeCore
import SwiftUI
import UniformTypeIdentifiers

/// Chooses a Chrome profile and optional sites before importing their cookies
/// into the workspace browser. Progress shows as an overlay on the browser.
struct ChromeCookieImportSheet: View {
    @Environment(WorkspaceBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var profileScan: Result<[ChromeProfile], Error>?
    @State private var profileID: ChromeProfile.ID?
    @State private var sites = ""
    @State private var choosingFolder = false
    @State private var scanDirectory = ChromeCookieImporter.chromeDirectory
    @State private var scanID = UUID()

    private var selectedProfile: ChromeProfile? {
        guard case .success(let profiles)? = profileScan else { return nil }
        return profiles.first { $0.id == profileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch profileScan {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let error)?:
                profilesUnavailable("Can’t read Chrome profiles", description: Text(error.localizedDescription))
            case .success(let profiles)? where profiles.isEmpty:
                profilesUnavailable(
                    "No Chrome profiles found",
                    description: Text("Open Chrome and visit a website, or choose the folder that contains your Chrome profiles.")
                )
            case .success(let profiles)?:
                Form {
                    Section {
                        Picker("Profile", selection: $profileID) {
                            ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField("Sites", text: $sites, prompt: Text("All sites"))
                            .accessibilityIdentifier("chrome-cookie-sites")
                    } footer: {
                        Text("Separate sites with commas, such as github.com, vercel.com. macOS asks before RxCode can read Chrome Safe Storage. Cookies stay on this Mac.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Import Cookies from Chrome")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    guard let profile = selectedProfile else { return }
                    let sites = ChromeCookieImporter.sites(from: sites)
                    dismiss()
                    Task { await browser.importChromeCookies(from: profile, sites: sites) }
                }
                .disabled(selectedProfile == nil)
                .accessibilityIdentifier("chrome-cookie-import")
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let directory):
                scanDirectory = directory
                profileScan = nil
                scanID = UUID()
            case .failure(let error):
                profileScan = .failure(error)
            }
        }
        .fileDialogDefaultDirectory(ChromeCookieImporter.chromeDirectory.deletingLastPathComponent())
        .task(id: scanID) {
            let directory = scanDirectory
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ChromeCookieImporter.profiles(in: directory) }
            }.value
            guard !Task.isCancelled else { return }
            profileScan = result
            profileID = (try? result.get())?.first?.id
        }
    }

    private func profilesUnavailable(_ title: LocalizedStringKey, description: Text) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "globe")
        } description: {
            description
        } actions: {
            Button("Choose Chrome Folder…") { choosingFolder = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Status overlay for the latest cookie import.
struct CookieImportStatusOverlay: View {
    @Environment(WorkspaceBrowser.self) private var browser

    var body: some View {
        if let status = browser.cookieImportStatus {
            HStack(spacing: 10) {
                switch status {
                case .importing:
                    ProgressView().controlSize(.small)
                    Text("Importing Chrome cookies…")
                case .imported(let count):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ClaudeTheme.statusSuccess)
                    Text("Imported \(count) cookies")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ClaudeTheme.statusWarning)
                    Text(message).lineLimit(3)
                    Button("Dismiss") { browser.cookieImportStatus = nil }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .task(id: status) {
                guard case .imported = status else { return }
                try? await Task.sleep(for: .seconds(3))
                if browser.cookieImportStatus == status {
                    withAnimation { browser.cookieImportStatus = nil }
                }
            }
        }
    }
}
