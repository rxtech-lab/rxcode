import Foundation
import Metal

// MARK: - Weight format

/// How a model's weights are stored, which decides the runtime that serves it.
nonisolated enum LocalModelWeightFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    /// llama.cpp GGUF files — one file (or split parts) per quantization.
    case gguf
    /// Apple MLX safetensors — the whole repo is one quantization.
    case mlx

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gguf: "GGUF"
        case .mlx: "MLX"
        }
    }

    var runtimeName: String {
        switch self {
        case .gguf: "llama.cpp"
        case .mlx: "MLX"
        }
    }
}

// MARK: - Installed model

/// A GGUF or MLX model downloaded from Hugging Face and available to the local agent.
nonisolated struct LocalModelInfo: Codable, Identifiable, Hashable, Sendable {
    /// GGUF: `<repo>/<first file>` — stable across relaunches and unique per
    /// quantization. MLX: the repo, which holds exactly one quantization.
    var id: String { format == .mlx ? repoID : "\(repoID)/\(files.first ?? "")" }
    let repoID: String
    let author: String
    /// GGUF: file names in load order, more than one for split models.
    /// MLX: every file of the repo, as paths relative to its root.
    let files: [String]
    let sizeBytes: Int64
    let parameterCount: Int64?
    let contextLength: Int?
    let architecture: String?
    let quantization: String?
    let downloadedAt: Date
    var format: LocalModelWeightFormat = .gguf

    var displayName: String {
        let base = repoID.split(separator: "/").last.map(String.init) ?? repoID
        let trimmed = LocalModelFormat.trimmingFormatSuffix(base)
        // MLX repo names usually carry the quantization already (`…-4bit`).
        if format == .mlx, LocalModelFormat.mlxQuantization(repoID: base, bits: nil) != nil { return trimmed }
        return quantization.map { "\(trimmed) · \($0)" } ?? trimmed
    }

    /// Directory holding this model's files.
    func directory(in root: URL) -> URL {
        root.appending(path: repoID.replacingOccurrences(of: "/", with: "__"))
    }

    /// What the runtime loads: the first GGUF file, or the MLX model directory.
    func primaryFile(in root: URL) -> URL {
        format == .mlx ? directory(in: root) : directory(in: root).appending(path: files.first ?? "")
    }
}

extension LocalModelInfo {
    private enum CodingKeys: String, CodingKey {
        case repoID, author, files, sizeBytes, parameterCount, contextLength, architecture, quantization, downloadedAt, format
    }

    /// Entries saved before MLX support have no `format`; they are GGUF.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repoID = try container.decode(String.self, forKey: .repoID)
        author = try container.decode(String.self, forKey: .author)
        files = try container.decode([String].self, forKey: .files)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        parameterCount = try container.decodeIfPresent(Int64.self, forKey: .parameterCount)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        architecture = try container.decodeIfPresent(String.self, forKey: .architecture)
        quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
        downloadedAt = try container.decode(Date.self, forKey: .downloadedAt)
        format = try container.decodeIfPresent(LocalModelWeightFormat.self, forKey: .format) ?? .gguf
    }
}

// MARK: - Hugging Face catalog

nonisolated struct HFModelSummary: Identifiable, Hashable, Sendable {
    let id: String
    let author: String
    let downloads: Int
    let likes: Int
    let parameterCount: Int64?
    let contextLength: Int?
    let architecture: String?
    let lastModified: Date?
    var format: LocalModelWeightFormat = .gguf
    /// Only visible to its owner; downloads need the owner signed in.
    var isPrivate = false
    /// Public, but downloads need a signed-in account granted access.
    var isGated = false

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
}

/// One page of Hugging Face search results.
nonisolated struct HFModelPage: Sendable {
    let models: [HFModelSummary]
    /// The next page, from the response's `Link: <…>; rel="next"` header.
    let next: URL?
}

/// One downloadable variant of a repo: a single GGUF, the parts of a split
/// one, or every file of an MLX repo.
nonisolated struct HFModelVariant: Identifiable, Hashable, Sendable {
    var id: String { files.first ?? "" }
    let files: [String]
    let sizeBytes: Int64
    let quantization: String?

    var displayName: String { quantization ?? (files.first ?? "") }
}

// MARK: - Hardware

/// How well a model of a given size runs on this Mac.
nonisolated enum LocalModelFit: Int, Comparable, Sendable {
    /// Comfortable headroom for the KV cache and other apps.
    case recommended
    /// Runs, with less headroom.
    case fits
    /// Uses nearly all GPU memory; expect slowdowns and memory pressure.
    case tight
    /// Larger than this Mac can hold in GPU memory.
    case tooLarge

    static func < (lhs: LocalModelFit, rhs: LocalModelFit) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .recommended: "Runs well"
        case .fits: "Fits"
        case .tight: "Tight fit"
        case .tooLarge: "Too large"
        }
    }

    var systemImage: String {
        switch self {
        case .recommended: "checkmark.seal.fill"
        case .fits: "checkmark.circle"
        case .tight: "exclamationmark.triangle"
        case .tooLarge: "xmark.octagon"
        }
    }

    /// Downloads at this fit or worse ask for confirmation first.
    var needsWarning: Bool { self >= .tight }
}

nonisolated struct LocalHardwareProfile: Sendable, Hashable {
    let chip: String
    let memoryBytes: Int64
    /// What Metal reports it can keep resident for the GPU — roughly 65–75% of
    /// unified memory on Apple silicon.
    let gpuBudgetBytes: Int64

    static let current: LocalHardwareProfile = {
        let memory = Int64(ProcessInfo.processInfo.physicalMemory)
        let metal = MTLCreateSystemDefaultDevice().map { Int64($0.recommendedMaxWorkingSetSize) } ?? 0
        return LocalHardwareProfile(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
            memoryBytes: memory,
            gpuBudgetBytes: metal > 0 ? metal : memory * 2 / 3
        )
    }()

    /// Weights plus a KV cache and runtime overhead estimate.
    func fit(forModelBytes bytes: Int64) -> LocalModelFit {
        let needed = Double(bytes) * 1.1 + 1.5 * 1_073_741_824
        let budget = Double(gpuBudgetBytes)
        if needed <= budget * 0.6 { return .recommended }
        if needed <= budget * 0.85 { return .fits }
        if needed <= budget { return .tight }
        return .tooLarge
    }

    /// Context window the server is started with when the user has not chosen
    /// one: larger windows cost KV-cache memory on top of the weights.
    var defaultContextSize: Int {
        let gigabytes = memoryBytes / 1_073_741_824
        if gigabytes >= 64 { return 65_536 }
        if gigabytes >= 32 { return 32_768 }
        if gigabytes >= 16 { return 16_384 }
        return 8_192
    }

    var memoryDescription: String {
        ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Formatting

nonisolated enum LocalModelFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// `8190735360` → `8.2B`.
    static func parameters(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        let billions = Double(value) / 1_000_000_000
        if billions >= 1 { return String(format: billions >= 10 ? "%.0fB" : "%.1fB", billions) }
        return String(format: "%.0fM", Double(value) / 1_000_000)
    }

    /// `Qwen3-8B-4bit-MLX` → `Qwen3-8B-4bit`.
    static func trimmingFormatSuffix(_ name: String) -> String {
        var result = name
        for suffix in ["-GGUF", "-gguf", "-MLX", "-mlx"] {
            result = result.replacingOccurrences(of: suffix, with: "")
        }
        return result
    }

    /// MLX quantization from a repo name (`Qwen3-8B-4bit` → `4-bit`), falling
    /// back to the bit width in its `config.json`.
    static func mlxQuantization(repoID: String, bits: Int?) -> String? {
        let pattern = #/(?i)(\d{1,2})[-_]?bit|(bf16|fp16|mxfp4)/#
        if let match = repoID.firstMatch(of: pattern) {
            if let bits = match.output.1 { return "\(bits)-bit" }
            if let type = match.output.2 { return String(type).uppercased() }
        }
        return bits.map { "\($0)-bit" }
    }

    /// `Qwen3-8B-Q4_K_M.gguf` → `Q4_K_M`.
    static func quantization(from file: String) -> String? {
        let pattern = #/(?i)(UD-)?(IQ\d_[A-Z0-9]+|Q\d(_[A-Z0-9]+)*|MXFP4|BF16|F16|F32)/#
        guard let match = file.firstMatch(of: pattern) else { return nil }
        return String(match.output.0).uppercased()
    }
}
