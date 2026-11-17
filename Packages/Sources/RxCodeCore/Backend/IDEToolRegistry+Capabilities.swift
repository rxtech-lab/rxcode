import Foundation

extension IDEToolRegistry {
    /// Returns the tools that should be exposed to an agent whose declared
    /// capabilities are `capabilities`. Polyfill tools whose capability is
    /// already covered natively are filtered out; `alwaysIDEOnly` tools
    /// always pass through.
    public static func tools(for capabilities: CapabilitySet) -> [IDETool] {
        allTools.filter { tool in
            switch tool.visibility {
            case .polyfill(let cap):
                return !capabilities.contains(cap)
            case .alwaysIDEOnly:
                return true
            }
        }
    }
}
