import Foundation

public struct MakeRunConfig: Codable, Sendable, Hashable {
    /// File name (relative to project root) of the Makefile to drive `make`.
    /// Empty defaults to `make`'s normal lookup (Makefile / makefile / GNUmakefile).
    public var makefile: String
    public var target: String
    /// Extra arguments appended after the target (e.g. `VAR=value`).
    public var arguments: String

    public init(
        makefile: String = "",
        target: String = "",
        arguments: String = ""
    ) {
        self.makefile = makefile
        self.target = target
        self.arguments = arguments
    }
}
