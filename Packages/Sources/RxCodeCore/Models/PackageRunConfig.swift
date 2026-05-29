import Foundation

/// A JavaScript/TypeScript package manager (or runtime task runner) capable of
/// running a named script from `package.json` (or `deno.json` tasks).
public enum PackageManager: String, Codable, Sendable, CaseIterable, Hashable {
    case npm
    case yarn
    case pnpm
    case bun
    case deno

    /// Command prefix that precedes the script name. npm and pnpm require an
    /// explicit `run`; yarn/bun take the script directly; deno uses `deno task`.
    public var runPrefix: String {
        switch self {
        case .npm: return "npm run"
        case .yarn: return "yarn"
        case .pnpm: return "pnpm run"
        case .bun: return "bun run"
        case .deno: return "deno task"
        }
    }

    /// Executable name used for install detection (`command -v <executable>`).
    public var executable: String { rawValue }

    public var displayName: String { rawValue }
}

/// Configuration for a `.packageScript` run profile: run a named script through
/// a selected package manager, with optional extra arguments appended verbatim
/// after the script (e.g. `bun run dev -- --port 3000`).
public struct PackageRunConfig: Codable, Sendable, Hashable {
    public var packageManager: PackageManager
    /// The script/task name, e.g. `dev`.
    public var script: String
    /// Extra arguments appended after the script. Free-form so the user can pass
    /// `-- --port 3000` (npm-style separator) or plain flags.
    public var arguments: String

    public init(
        packageManager: PackageManager = .npm,
        script: String = "",
        arguments: String = ""
    ) {
        self.packageManager = packageManager
        self.script = script
        self.arguments = arguments
    }
}
