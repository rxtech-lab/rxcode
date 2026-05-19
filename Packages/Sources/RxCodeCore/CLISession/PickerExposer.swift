import Foundation
import os

#if os(macOS)

/// Rewrites Claude Code session jsonl files so that RxCode-spawned sessions
/// appear in the interactive `claude --resume` picker.
///
/// The CLI tags every line with `"entrypoint":"sdk-cli"` and prepends
/// `type: queue-operation` envelope lines whenever it is launched in print
/// mode (`-p`), which is how RxCode spawns it. The picker filters those
/// sessions out, so without this normalization RxCode's history is invisible
/// to anyone running `claude --resume` outside the app. Rewriting the file
/// to look like a regular interactive session lets the picker pick it up.
///
/// Patches are skipped while a sessionId is registered as live in
/// `~/.claude/sessions/<pid>.json`, so we never race the CLI's append.
public enum PickerExposer {

    private static let logger = Logger(subsystem: "com.claudework", category: "PickerExposer")

    private static let entrypointMarker = "\"entrypoint\":\"sdk-cli\""
    private static let entrypointReplacement = "\"entrypoint\":\"cli\""
    private static let queueOperationMarker = "\"type\":\"queue-operation\""

    /// Rewrite a single jsonl file. No-op if the session is still live.
    public static func normalize(jsonlAt url: URL) async {
        let sid = url.deletingPathExtension().lastPathComponent
        await Task.detached(priority: .utility) {
            if liveSessionIds().contains(sid) { return }
            normalizeSync(jsonlAt: url)
        }.value
    }

    /// Set of sessionIds with a live PID-keyed metadata file under
    /// `~/.claude/sessions/`. The CLI writes those on launch and removes
    /// them on clean exit; we use them to skip files mid-append.
    private static func liveSessionIds() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }
        var ids = Set<String>()
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String
            else { continue }
            ids.insert(sid)
        }
        return ids
    }

    private static func normalizeSync(jsonlAt url: URL) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return }

        guard text.contains(entrypointMarker) || text.contains(queueOperationMarker) else {
            return
        }

        var out = String()
        out.reserveCapacity(text.utf8.count)
        var changed = false

        text.enumerateLines { line, _ in
            if line.contains(queueOperationMarker) {
                changed = true
                return
            }
            if line.contains(entrypointMarker) {
                out.append(line.replacingOccurrences(of: entrypointMarker, with: entrypointReplacement))
                out.append("\n")
                changed = true
                return
            }
            out.append(line)
            out.append("\n")
        }

        guard changed else { return }

        let dir = url.deletingLastPathComponent()
        // UUID-suffixed tmp avoids collisions when multiple normalizations
        // race on the same target.
        let tmp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).picker-tmp.\(UUID().uuidString)"
        )
        do {
            try Data(out.utf8).write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            logger.error(
                "normalize failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

#endif
