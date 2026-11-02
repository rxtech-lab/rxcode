import Foundation

/// Version output from Claude Code and Codex can include the runtime name.
public enum AgentRuntimeVersion {
    public static func parse(_ output: String?) -> String? {
        guard let output,
              let range = output.range(
                  of: #"(?<![0-9.])[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?![0-9.])"#,
                  options: .regularExpression
              )
        else { return nil }
        return String(output[range])
    }

    public static func isUpdate(_ candidate: String, for installedOutput: String?) -> Bool {
        let candidateCore = candidate.components(separatedBy: "+")[0]
        guard ACPPackageVersion.isValid(candidate), !candidateCore.contains("-"),
              let installed = parse(installedOutput)
        else { return false }
        let installedRelease = installed.components(separatedBy: "+")[0]
        let installedCore = installedRelease.components(separatedBy: "-")[0]
        let comparison = candidateCore.compare(installedCore, options: .numeric)
        return comparison == .orderedDescending
            || (comparison == .orderedSame && installedRelease.contains("-"))
    }
}
