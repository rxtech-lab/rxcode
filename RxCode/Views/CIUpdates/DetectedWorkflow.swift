import Foundation

/// A GitHub Actions workflow file found locally under `.github/workflows`.
/// Mirrors `DetectedEnv` — `CIUpdateHook` uses this to decide, without hitting
/// the network, whether a project is even a candidate for the CI auto-update
/// banner (a repo with no workflow files has nothing to keep updated).
struct DetectedWorkflow: Identifiable {
    let filename: String
    var id: String { filename }

    /// Scans `<directory>/.github/workflows` for `*.yml` / `*.yaml` files.
    /// Returns an empty array when the directory is missing or unreadable.
    static func scan(directory: String?) -> [DetectedWorkflow] {
        guard let directory else { return [] }
        let workflowsDir = (directory as NSString).appendingPathComponent(".github/workflows")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workflowsDir) else { return [] }
        return names
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .sorted()
            .compactMap { name in
                let path = (workflowsDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                    return nil
                }
                return DetectedWorkflow(filename: name)
            }
    }
}
