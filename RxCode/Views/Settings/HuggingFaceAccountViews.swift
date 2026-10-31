import RxCodeCore
import SwiftUI

/// The Hugging Face account in the Local Models toolbar: a sign-in button, or
/// the signed-in account with profile and sign-out actions.
struct HuggingFaceAccountButton: View {
    @Environment(AppState.self) private var appState
    @Binding var showSignIn: Bool
    @State private var confirmSignOut = false

    private var accounts: HuggingFaceAccountStore { appState.localModels.huggingFace }

    var body: some View {
        if let account = accounts.account {
            Menu {
                Text("Signed in as \(account.username)")
                Button("Open Profile on Hugging Face") { NSWorkspace.shared.open(account.profileURL) }
                Divider()
                Button("Sign Out…", role: .destructive) { confirmSignOut = true }
            } label: {
                HStack(spacing: 6) {
                    HuggingFaceAvatar(url: account.avatarURL)
                    Text(account.username)
                }
            }
            .fixedSize()
            .help("Signed in to Hugging Face")
            .alert("Sign out of Hugging Face?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    Task { await accounts.signOut() }
                }
            } message: {
                Text("Private and gated models will no longer be available to browse or download. Models already downloaded stay on this Mac.")
            }
        } else {
            Button {
                showSignIn = true
            } label: {
                Label("Sign In to Hugging Face", systemImage: "person.crop.circle")
            }
            .help("Sign in to download your private models and gated models you have access to")
        }
    }
}

struct HuggingFaceAvatar: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
    }
}

/// Sign in to Hugging Face in the browser (OAuth), or with a user access token.
struct HuggingFaceSignInSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var progress: String?
    @State private var errorMessage: String?
    @State private var work: Task<Void, Never>?

    private var accounts: HuggingFaceAccountStore { appState.localModels.huggingFace }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Signing in lets the RxCode Agent browse and download your private models and public gated models your account has been granted access to.")
                            .foregroundStyle(.secondary)
                        Button {
                            run("Waiting for Hugging Face in your browser…") {
                                try await accounts.signInWithBrowser()
                            }
                        } label: {
                            Label("Sign In with Hugging Face", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(progress != nil)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Browser")
                } footer: {
                    Text("RxCode asks for read access to your profile, your repositories and the gated repositories you can open. It never gets write access.")
                }

                Section {
                    SecureField("Access token", text: $token, prompt: Text("hf_…"))
                        .onSubmit(signInWithToken)
                    HStack {
                        Link("Create a token on Hugging Face…", destination: HuggingFaceOAuth.tokenSettingsURL)
                            .font(.system(size: ClaudeTheme.size(11)))
                        Spacer()
                        Button("Sign In with Token", action: signInWithToken)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || progress != nil)
                    }
                } header: {
                    Text("Access Token")
                } footer: {
                    Text("Use a token with read access instead of signing in in the browser. It is stored in your Keychain.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sign In to Hugging Face")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancel()
                        dismiss()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { progressOverlay }
        .alert("Couldn't Sign In", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear(perform: cancel)
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let progress {
            ZStack {
                Color.black.opacity(0.15).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(progress).font(.callout)
                    Button("Cancel", action: cancel)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func signInWithToken() {
        let value = token
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, progress == nil else { return }
        run("Checking the access token…") {
            try await accounts.signIn(accessToken: value)
        }
    }

    private func run(_ message: String, _ operation: @escaping @MainActor () async throws -> Void) {
        progress = message
        work = Task {
            defer { progress = nil; work = nil }
            do {
                try await operation()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        accounts.cancelSignIn()
        work?.cancel()
    }
}
