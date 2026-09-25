import AppKit
import Foundation
import RxCodeCore

extension CodexAppServer {
    /// Keep this app-server alive until its browser callback completes. The
    /// callback listener belongs to the process that started the login.
    func signIn() async throws {
        guard let binary = await findCodexBinary() else { throw CodexError.binaryNotFound }
        let streamId = UUID()
        let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: nil)
        defer { finalize(streamId: streamId) }

        try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)
        try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
        try Self.writeJSONLine(Self.request(id: 2, method: "account/login/start", params: [
            "type": .string("chatgpt"),
            "useHostedLoginSuccessPage": .bool(true),
            "appBrand": .string("codex"),
        ]), to: handles.stdin)

        var loginId: String?
        for try await line in handles.stdout.fileHandleForReading.bytes.lines {
            try Task.checkCancellation()
            guard let object = Self.decodeObject(line) else { continue }
            if let requestId = Self.idString(object["id"]), object["method"] != nil {
                try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: handles.stdin)
                continue
            }
            if Self.idString(object["id"]) == "2" {
                if let message = object["error"]?.objectValue?["message"]?.stringValue {
                    throw CodexError.loginFailed(message)
                }
                guard let result = object["result"]?.objectValue,
                      let authURL = result["authUrl"]?.stringValue,
                      let url = URL(string: authURL),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                else { throw CodexError.loginFailed("The app server did not return a sign-in URL.") }
                loginId = result["loginId"]?.stringValue
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                guard opened else { throw CodexError.loginFailed("Could not open the sign-in page.") }
            }
            if object["method"]?.stringValue == "account/login/completed",
               let params = object["params"]?.objectValue,
               params["loginId"]?.stringValue == loginId {
                if params["success"]?.boolValue == true { return }
                throw CodexError.loginFailed(params["error"]?.stringValue ?? "The sign-in was cancelled.")
            }
        }
        throw CodexError.loginFailed("The app server closed before sign-in completed.")
    }
}
