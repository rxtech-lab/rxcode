import Foundation

/// Pure helpers used by `RunService` to assemble subprocess inputs from a
/// `RunProfile`. No I/O except `FileManager.fileExists` / `Data(contentsOf:)`
/// for resolving the `.env` file path, which keeps the helper testable.
public enum RunTaskExecutor {

    // MARK: - Working directory

    /// Resolve a user-entered working directory string against a project root.
    /// - Absolute paths (and `~`-prefixed) are returned standardized.
    /// - Empty or whitespace-only strings fall back to the project path.
    /// - Anything else is joined onto the project path.
    public static func resolveWorkingDirectory(_ raw: String, projectPath: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (projectPath as NSString).standardizingPath }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        let joined = (projectPath as NSString).appendingPathComponent(expanded)
        return (joined as NSString).standardizingPath
    }

    // MARK: - Environment

    /// Resolve a preset (optionally loading from a .env file, optionally
    /// overlaying manual KV pairs) on top of a base environment.
    ///
    /// Precedence (low → high): base < file < manualVars.
    /// Missing files are silently ignored (no throw) so a typo in the path
    /// doesn't block the run — the user will see the missing keys in the
    /// terminal output and can fix the path.
    public static func resolveEnvironment(
        preset: EnvironmentPreset?,
        projectPath: String,
        baseEnvironment: [String: String],
        fileLoader: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> [String: String] {
        var env = baseEnvironment
        guard let preset else { return env }

        if preset.loadFromFile, let raw = preset.envFilePath {
            let resolved = resolveWorkingDirectory(raw, projectPath: projectPath)
            if let contents = fileLoader(resolved) {
                for (k, v) in RunEnvFileParser.parse(contents) { env[k] = v }
            }
        }

        if preset.useManualKV {
            for v in preset.manualVars {
                let key = v.key.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                env[key] = v.value
            }
        }

        return env
    }

    // MARK: - Wrapper script

    /// Build the bash script that runs before-steps, the main command, and
    /// after-steps in sequence. The trap is installed *before* `cd` so a
    /// missing working directory still prints the exit footer — otherwise the
    /// terminal goes blank with no indication of what happened.
    ///
    /// Note: banner text is intentionally plain ASCII without SGR styling.
    /// SwiftTerm renders SGR 2 (dim) as low-contrast on dark backgrounds,
    /// which made the banners invisible in earlier versions.
    public static func buildWrapperScript(profile: RunProfile, projectPath: String) -> String {
        let cwd = resolveWorkingDirectory(profile.bash.workingDirectory, projectPath: projectPath)

        let afterSteps = profile.afterSteps.filter { !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }

        var lines: [String] = []
        lines.append("#!/usr/bin/env bash")
        // macOS apps launched from Finder get the bare system PATH
        // (/usr/bin:/bin:/usr/sbin:/sbin), so user-installed tools like
        // `bun`, `pnpm`, `pyenv` aren't visible to subprocesses. Most users
        // configure these in ~/.zshrc, which is only sourced by interactive
        // zsh. We can't run our wrapper directly under `zsh -ic` because of
        // a zsh quirk (`set -e` + a builtin like `cd` exits with code 1 and
        // skips the EXIT trap). Workaround: run interactive zsh in a
        // *subshell* purely to capture PATH — subshell state (traps, set -e
        // weirdness) can't leak back here.
        lines.append("__rxcode_user_path=$(/bin/zsh -ic 'printf %s \"$PATH\"' 2>/dev/null)")
        lines.append("[ -n \"$__rxcode_user_path\" ] && export PATH=\"$__rxcode_user_path\"")
        lines.append("")
        // Trap is registered first so it fires for any subsequent failure —
        // including a failing `cd` into a stale working directory.
        lines.append("__rxcode_after() {")
        lines.append("  local __rxcode_rc=$?")
        lines.append("  set +e")
        for step in afterSteps {
            lines.append("  \(step.command)")
        }
        lines.append("  printf '\\n[rxcode] exited with code %d\\n' \"$__rxcode_rc\"")
        lines.append("  return $__rxcode_rc")
        lines.append("}")
        lines.append("trap __rxcode_after EXIT")
        lines.append("")
        lines.append("printf '[rxcode] starting in %s\\n' \(shellEscape(cwd))")
        lines.append("set -e")
        lines.append("cd \(shellEscape(cwd))")
        lines.append("")

        let beforeSteps = profile.beforeSteps.filter { !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        if !beforeSteps.isEmpty {
            lines.append("# --- before launch ---")
            for step in beforeSteps {
                lines.append(step.command)
            }
            lines.append("")
        }

        let mainLines = mainCommandLines(for: profile)
        if !mainLines.isEmpty {
            lines.append("# --- main ---")
            lines.append(contentsOf: mainLines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Produce the script lines for the profile's main command. For `.bash`
    /// this is just the user-typed string; for `.xcode` we synthesize the
    /// appropriate `xcodebuild` invocation (and, for `.run`, locate the built
    /// `.app` from build settings and `open` it); for `.make` we synthesize
    /// a `make` invocation against the configured Makefile and target.
    static func mainCommandLines(for profile: RunProfile) -> [String] {
        switch profile.type {
        case .bash:
            let cmd = profile.bash.command.trimmingCharacters(in: .whitespaces)
            return cmd.isEmpty ? [] : [cmd]
        case .xcode:
            guard let xcode = profile.xcode,
                  !xcode.container.isEmpty,
                  !xcode.scheme.isEmpty
            else { return [] }
            return xcodeScriptLines(xcode)
        case .make:
            guard let make = profile.make else { return [] }
            return makeScriptLines(make)
        }
    }

    private static func xcodeScriptLines(_ cfg: XcodeRunConfig) -> [String] {
        let containerFlag = cfg.isWorkspace ? "-workspace" : "-project"
        let container = shellEscape(cfg.container)
        let scheme = shellEscape(cfg.scheme)
        let configuration = shellEscape(cfg.configuration)
        let destination = cfg.destination.trimmingCharacters(in: .whitespaces)

        var base = "xcodebuild \(containerFlag) \(container) -scheme \(scheme) -configuration \(configuration)"
        if !destination.isEmpty {
            base += " -destination \(shellEscape(destination))"
        }

        switch cfg.action {
        case .build:
            return ["\(base) build"]
        case .clean:
            return ["\(base) clean"]
        case .test:
            return ["\(base) test"]
        case .run:
            // Build, then resolve BUILT_PRODUCTS_DIR / FULL_PRODUCT_NAME from
            // `-showBuildSettings` and `open` the resulting bundle. `-n`
            // forces a fresh instance — without it, `open` just activates an
            // already-running copy (common when iterating on an app you
            // launched a moment ago), making Run feel like a no-op.
            return [
                "\(base) build",
                "__rxcode_settings=$(\(base) -showBuildSettings 2>/dev/null)",
                "__rxcode_build_dir=$(printf '%s\\n' \"$__rxcode_settings\" | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR =/ {print $2; exit}')",
                "__rxcode_product=$(printf '%s\\n' \"$__rxcode_settings\" | awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME =/ {print $2; exit}')",
                "if [ -n \"$__rxcode_build_dir\" ] && [ -n \"$__rxcode_product\" ]; then",
                "  printf '[rxcode] launching %s\\n' \"$__rxcode_build_dir/$__rxcode_product\"",
                "  open -n \"$__rxcode_build_dir/$__rxcode_product\"",
                "else",
                "  printf '[rxcode] could not resolve built product to launch\\n' 1>&2",
                "  exit 1",
                "fi",
            ]
        }
    }

    private static func makeScriptLines(_ cfg: MakeRunConfig) -> [String] {
        let makefile = cfg.makefile.trimmingCharacters(in: .whitespaces)
        let target = cfg.target.trimmingCharacters(in: .whitespaces)
        let args = cfg.arguments.trimmingCharacters(in: .whitespaces)
        // An untouched profile has nothing to run; skip the main command so
        // we don't shell out to a default `make` and surprise the user.
        if makefile.isEmpty && target.isEmpty && args.isEmpty { return [] }

        var parts: [String] = ["make"]
        if !makefile.isEmpty {
            parts.append("-f")
            parts.append(shellEscape(makefile))
        }
        if !target.isEmpty {
            parts.append(shellEscape(target))
        }
        if !args.isEmpty {
            parts.append(args)
        }
        return [parts.joined(separator: " ")]
    }

    /// Escapes a path for safe inclusion as a single-quoted bash literal.
    /// `'` inside the path is encoded as `'\''`.
    public static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
