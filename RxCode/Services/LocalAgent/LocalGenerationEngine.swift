import Foundation
import enum RxCodeCore.LocalStudioKind
import struct RxCodeCore.LocalStudioPreferences

/// An engine a local studio can run its model with. Each studio remembers
/// its choice (`LocalStudioPreferences.engineID`), so a new engine for one
/// kind of model can be picked without changing the others.
nonisolated enum LocalGenerationEngine: String, CaseIterable, Identifiable, Sendable {
    /// Media packages and the bundled native decision scorer.
    case mlxImage, mlxAudio, mlxVideo, mlxVerdict
    /// stable-diffusion.cpp's `sd-cli`: video and image diffusion GGUFs.
    case stableDiffusion
    /// llama.cpp's `llama-tts`: text-to-speech GGUFs.
    case llamaSpeech
    /// llama.cpp's `llama-mtmd-cli`: audio-in multimodal GGUFs.
    case llamaAudioInput
    /// llama.cpp's `llama-server`, read at verdict slots: decision GGUFs.
    case llamaVerdict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mlxImage: "MLX Image (MFLUX)"
        case .mlxAudio: "MLX Audio"
        case .mlxVideo: "MLX Video"
        case .mlxVerdict: "MLX verdict readout (native Swift)"
        case .stableDiffusion: "stable-diffusion.cpp"
        case .llamaSpeech: "llama.cpp speech (llama-tts)"
        case .llamaAudioInput: "llama.cpp audio input (llama-mtmd-cli)"
        case .llamaVerdict: "llama.cpp verdict readout (llama-server)"
        }
    }

    var summary: String {
        switch self {
        case .mlxImage: "MLX image generation with MFLUX. Installs an isolated Python runtime on first use; requires uv."
        case .mlxAudio: "MLX speech and transcription. Installs an isolated Python runtime on first use; requires uv."
        case .mlxVideo: "MLX LTX-2 and Wan video generation. Installs an isolated Python runtime on first use; requires uv."
        case .mlxVerdict: "Reads yes/no logits at each verdict slot using the bundled Swift MLX engine."
        case .stableDiffusion: "Metal accelerated diffusion. Runs video and image GGUF models with their text encoders and VAE."
        case .llamaSpeech: "Speaks text with llama.cpp speech models such as OuteTTS, with their vocoder."
        case .llamaAudioInput: "Transcribes and reads audio with llama.cpp multimodal models and their audio projector."
        case .llamaVerdict: "Scores each option at the model's verdict slot, calibrated when the model ships a readout config."
        }
    }

    var runtime: LocalRuntimeComponent {
        switch self {
        case .mlxImage, .mlxAudio, .mlxVideo, .mlxVerdict: .mlx
        case .stableDiffusion: .stableDiffusion
        case .llamaSpeech, .llamaAudioInput, .llamaVerdict: .llamaCpp
        }
    }

    var kinds: Set<LocalStudioKind> {
        switch self {
        case .mlxImage: [.image]
        case .mlxAudio: [.audio]
        case .mlxVideo: [.video]
        case .mlxVerdict: [.decision]
        case .stableDiffusion: [.video, .image]
        case .llamaSpeech, .llamaAudioInput: [.audio]
        case .llamaVerdict: [.decision]
        }
    }

    static func engines(for kind: LocalStudioKind) -> [Self] {
        allCases.filter { $0.kinds.contains(kind) }
    }

    /// Why this engine can't run `model`, or nil when it can.
    func incompatibility(with model: LocalModelInfo) -> String? {
        guard kinds.contains(model.studioKind) else { return "Not a \(model.studioKind.rawValue) engine." }
        if [.mlxImage, .mlxAudio, .mlxVideo, .mlxVerdict].contains(self) {
            guard model.format == .mlx else { return "\(title) runs MLX models; this is a GGUF model." }
            guard LlamaRuntimeInstaller.isAppleSilicon else { return "MLX requires Apple silicon." }
            if self == .mlxImage, MLXStudioMedia.imageFamily(model) == nil {
                return "MFLUX currently supports FLUX.1, Z-Image Turbo and Qwen Image in this studio."
            }
            if self == .mlxVideo, MLXStudioMedia.videoFamily(model) == nil {
                return "MLX Video currently supports LTX-2 and Wan 2.1/2.2 in this studio."
            }
            return nil
        }
        guard model.format == .gguf else { return "\(title) runs GGUF models; this is an \(model.format.label) model." }
        switch self {
        case .stableDiffusion:
            if model.studioKind == .video, !LocalVideoRecipe.supports(model) {
                return "RxCode does not yet support this video architecture."
            }
        case .llamaSpeech:
            if LocalAudioMode(model: model) != .speech { return "This model reads audio rather than speaking." }
        case .llamaAudioInput:
            if LocalAudioMode(model: model) != .transcription { return "This model speaks rather than reading audio." }
        case .llamaVerdict, .mlxImage, .mlxAudio, .mlxVideo, .mlxVerdict:
            break
        }
        return nil
    }

    /// The engine a studio runs `model` with: the remembered choice when it
    /// can run the model, else the first that can.
    static func resolve(for model: LocalModelInfo, preferences: LocalStudioPreferences) -> Self? {
        if let id = preferences.engineID, let chosen = Self(rawValue: id), chosen.incompatibility(with: model) == nil {
            return chosen
        }
        return engines(for: model.studioKind).first { $0.incompatibility(with: model) == nil }
    }
}
