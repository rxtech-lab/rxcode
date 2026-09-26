import RxCodeCore
import SwiftUI

// MARK: - ACP Sign In Sheet

/// Lists the sign-in methods an ACP client advertises and runs the chosen
/// one: the agent-driven `authenticate` call, an interactive Terminal login,
/// or credentials stored as launch environment variables.
struct ACPSignInSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let client: ACPClientSpec
    let isSignedIn: Bool

    @State private var methods: [ACPAuthMethod] = []
    @State private var isLoadingMethods = false
    @State private var loadError: String?
    @State private var selectedMethodId: String?
    @State private var envValues: [String: String] = [:]
    @State private var isSigningIn = false
    @State private var finishedMessage: String?
    @State private var errorMessage: String?
    @State private var signInTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            methodsSection
            if let method = selectedMethod, case .envVar(let vars, let link) = method.kind {
                credentialFields(vars, link: link)
            }
            if isSigningIn || finishedMessage != nil {
                progressSection
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(ClaudeTheme.statusError)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(isSigningIn)
        .task { await loadMethods() }
        .onDisappear { signInTask?.cancel() }
    }

    private var selectedMethod: ACPAuthMethod? {
        methods.first { $0.id == selectedMethodId }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isSignedIn ? "Re-sign In to \(client.displayName)" : "Sign In to \(client.displayName)")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
            Text(signedInMethodName.map { "Last signed in with \($0)" } ?? "Choose how this client should authenticate.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private var signedInMethodName: String? {
        guard let id = client.authMethodId else { return nil }
        return methods.first { $0.id == id }?.name ?? id
    }

    @ViewBuilder
    private var methodsSection: some View {
        if isLoadingMethods {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading sign-in methods…")
            }
            .font(.system(size: ClaudeTheme.size(11)))
            .foregroundStyle(.secondary)
        } else if let loadError {
            HStack(spacing: 6) {
                Text(loadError)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await loadMethods() } }
                    .buttonStyle(.link)
            }
            .font(.system(size: ClaudeTheme.size(11)))
        } else if methods.isEmpty {
            Text("This client doesn't advertise any sign-in methods. It may use its own saved credentials or environment variables set in Edit.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 6) {
                ForEach(methods) { method in
                    methodRow(method)
                }
            }
        }
    }

    private func methodRow(_ method: ACPAuthMethod) -> some View {
        let isSelected = method.id == selectedMethodId
        return Button {
            selectedMethodId = method.id
            errorMessage = nil
            finishedMessage = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: ClaudeTheme.size(13)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(method.name)
                            .font(.system(size: ClaudeTheme.size(12), weight: .medium))
                        Text(kindLabel(method.kind))
                            .font(.system(size: ClaudeTheme.size(10), weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if let description = method.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
    }

    private func credentialFields(_ vars: [ACPAuthMethod.EnvVar], link: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(vars, id: \.name) { variable in
                VStack(alignment: .leading, spacing: 4) {
                    Text(variable.label ?? variable.name)
                        .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                    Group {
                        if variable.secret {
                            SecureField(variable.name, text: envBinding(variable.name))
                        } else {
                            TextField(variable.name, text: envBinding(variable.name))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSigningIn)
                }
            }
            if let link, let url = URL(string: link) {
                Link("Get credentials", destination: url)
                    .font(.system(size: ClaudeTheme.size(11)))
            }
            Text("Saved to this client's launch environment.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if finishedMessage != nil {
                ProgressView(value: 1)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(finishedMessage ?? "Waiting for sign-in… Complete it in your browser if one opened.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if finishedMessage != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") {
                    signInTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    signIn()
                } label: {
                    Text(isSigningIn ? "Signing In…" : (isSignedIn ? "Re-sign In" : "Sign In"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSigningIn || !canSignIn)
            }
        }
    }

    private var canSignIn: Bool {
        guard let method = selectedMethod else { return false }
        if case .envVar(let vars, _) = method.kind {
            return vars.allSatisfy { variable in
                variable.optional || !(envValues[variable.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        return true
    }

    private func kindLabel(_ kind: ACPAuthMethod.Kind) -> LocalizedStringKey {
        switch kind {
        case .agent: "Browser"
        case .envVar: "API Key"
        case .terminal: "Terminal"
        }
    }

    private func envBinding(_ name: String) -> Binding<String> {
        Binding(get: { envValues[name] ?? "" }, set: { envValues[name] = $0 })
    }

    private func loadMethods() async {
        isLoadingMethods = true
        loadError = nil
        defer { isLoadingMethods = false }
        do {
            methods = try await appState.acpAuthMethods(for: client.id)
            selectedMethodId = methods.first { $0.id == client.authMethodId }?.id ?? methods.first?.id
            for method in methods {
                guard case .envVar(let vars, _) = method.kind else { continue }
                for variable in vars where envValues[variable.name] == nil {
                    envValues[variable.name] = client.extraEnv[variable.name]
                }
            }
        } catch is CancellationError {
            return
        } catch {
            loadError = "Could not load sign-in methods: \(error.localizedDescription)"
        }
    }

    private func signIn() {
        guard let method = selectedMethod else { return }
        isSigningIn = true
        errorMessage = nil
        signInTask = Task {
            defer { isSigningIn = false }
            do {
                switch method.kind {
                case .agent:
                    try await appState.authenticateACPClient(id: client.id, methodId: method.id)
                    finishedMessage = String(localized: "Signed in to \(client.displayName).")
                case .envVar(let vars, _):
                    let values = Dictionary(uniqueKeysWithValues: vars.map { ($0.name, envValues[$0.name] ?? "") })
                    await appState.setACPClientCredentials(id: client.id, values: values)
                    finishedMessage = String(localized: "Credentials saved.")
                case .terminal:
                    try await appState.openACPTerminalLogin(id: client.id, method: method)
                    finishedMessage = String(localized: "Complete sign-in in Terminal.")
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
