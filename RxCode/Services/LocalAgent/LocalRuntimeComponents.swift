import Foundation

/// The engines the RxCode Agent runs local models with, as listed in
/// Settings → Agent → RxCode Agent → Manage → Runtimes.
nonisolated enum LocalRuntimeComponent: String, CaseIterable, Identifiable, Sendable {
    /// Apple MLX through MLX Swift — runs MLX safetensors in-process.
    case mlx
    /// llama.cpp's `llama-server`, Metal accelerated — runs GGUF files.
    case llamaCpp
    /// stable-diffusion.cpp's `sd-cli`, Metal accelerated — runs diffusion
    /// GGUF files (image and video generators) that llama.cpp cannot load.
    case stableDiffusion

    var id: String { rawValue }

    /// MLX is linked into RxCode, so its version mirrors `Package.resolved`;
    /// `LocalModelTests` fails when the two drift apart.
    static let mlxSwiftVersion = "0.32.3"
    static let mlxSwiftLMVersion = "3.32.3"

    var title: String {
        switch self {
        case .mlx: "MLX (Metal)"
        case .llamaCpp: "Metal llama.cpp"
        case .stableDiffusion: "stable-diffusion.cpp"
        }
    }

    var summary: String {
        switch self {
        case .mlx: "Bundled Swift MLX for text and decision models. Image, audio and video studios use separate MLX media packages installed on first use."
        case .llamaCpp: "Apple Metal accelerated llama.cpp engine. Runs GGUF models."
        case .stableDiffusion: "Apple Metal accelerated image and video generation engine. Runs diffusion GGUF models such as MiniMax-H3, not chat models."
        }
    }

    var systemImage: String {
        switch self {
        case .mlx: "cpu"
        case .llamaCpp: "bolt.horizontal"
        case .stableDiffusion: "film"
        }
    }
}
