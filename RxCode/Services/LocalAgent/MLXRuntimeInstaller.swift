import Foundation

/// Native MLX is linked into RxCode. No Python environment or server is installed.
/// Retains the runtime availability interface used by the model download UI.
nonisolated enum MLXRuntimeInstaller {
    enum InstallError: LocalizedError {
        case unsupportedMac
        var errorDescription: String? { "MLX models need a Mac with Apple silicon." }
    }

    static func locate(appSupport: URL) -> LlamaRuntimeInstaller.Runtime? {
        guard LlamaRuntimeInstaller.isAppleSilicon else { return nil }
        return .init(path: "", version: "Native Swift")
    }

    static func install(
        appSupport: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> LlamaRuntimeInstaller.Runtime {
        guard let runtime = locate(appSupport: appSupport) else { throw InstallError.unsupportedMac }
        return runtime
    }
}
