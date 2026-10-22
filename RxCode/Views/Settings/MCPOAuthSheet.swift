import SwiftUI
import AuthenticationServices
import RxCodeCore

@MainActor
private final class MCPOAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func retryWithHTTP() {
        session?.cancel()
        finish(.failure(MCPOAuthService.AuthError.invalid("Retrying with an HTTP callback.")))
    }

    func authenticate(url: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "rxcode") { [weak self] url, error in
                    Task { @MainActor in
                        if let url { self?.finish(.success(url)) }
                        else { self?.finish(.failure(error ?? CancellationError())) }
                    }
                }
                session.presentationContextProvider = self
                self.session = session
                if !session.start() {
                    finish(.failure(MCPOAuthService.AuthError.invalid("Could not open the sign-in browser.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.session?.cancel()
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

struct MCPOAuthSheet: View {
    let server: MCPServerInfo
    let onComplete: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var browser = MCPOAuthBrowser()
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    @State private var status: String?
    @State private var confirmSignOut = false
    @State private var canRetryWithHTTP = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MCP Authentication").font(.headline)
            Text(verbatim: server.name).font(.title3)
            Text(verbatim: server.endpoint).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("OAuth client ID (optional)", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .disabled(operation != nil)
            Text("Leave blank to register automatically when the server supports it.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Sign Out…", role: .destructive) { confirmSignOut = true }.disabled(operation != nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In", systemImage: "person.crop.circle.badge.checkmark") { signIn() }
                    .buttonStyle(.borderedProminent).disabled(operation != nil)
            }
        }
        .padding(24).frame(width: 480, height: 300)
        .overlay {
            if let status {
                VStack(spacing: 16) {
                    ProgressView(status)
                    if canRetryWithHTTP {
                        Button("Retry with HTTP Callback") { browser.retryWithHTTP() }
                    }
                    Button("Cancel", role: .cancel) { operation?.cancel() }
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("MCP Authentication", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(verbatim: error ?? "") }
        .confirmationDialog("Remove saved credentials for this server?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                operation = Task {
                    status = "Signing out…"
                    defer { status = nil; operation = nil }
                    do {
                        try await MCPOAuthService.shared.signOut(resource: server.endpoint)
                        await onComplete()
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .onDisappear { operation?.cancel() }
    }

    private func signIn() {
        operation = Task {
            status = "Signing in…"
            defer { status = nil; operation = nil; canRetryWithHTTP = false }
            do {
                guard let resource = URL(string: server.endpoint) else { return }
                let (authorization, callback) = try await authorize(resource: resource)
                try Task.checkCancellation()
                NSApp.activate(ignoringOtherApps: true)
                status = "Finishing sign-in…"
                try await MCPOAuthService.shared.complete(authorization, callback: callback)
                await onComplete()
                dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    private func authorize(resource: URL) async throws -> (MCPOAuthService.Authorization, URL) {
        do {
            let authorization = try await MCPOAuthService.shared.begin(resource: resource, clientID: clientID)
            try Task.checkCancellation()
            canRetryWithHTTP = true
            defer { canRetryWithHTTP = false }
            let callback = try await browser.authenticate(url: authorization.url)
            _ = try MCPOAuthService.callbackCode(authorization, callback: callback)
            return (authorization, callback)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw CancellationError()
        } catch MCPOAuthService.AuthError.denied {
            throw MCPOAuthService.AuthError.denied
        } catch {
            try Task.checkCancellation()
            status = "Signing in with HTTP callback…"
            let receiver = MCPOAuthCallbackServer()
            defer { receiver.stop() }
            let redirect = try await receiver.start()
            let authorization = try await MCPOAuthService.shared.begin(
                resource: resource, clientID: clientID, redirectURI: redirect.absoluteString
            )
            try Task.checkCancellation()
            let callback = try await receiver.wait(for: authorization) {
                NSWorkspace.shared.open(authorization.url)
            }
            return (authorization, callback)
        }
    }
}
