import Foundation

extension IDEToolRegistry {
    /// Returns the tools available for the agent's capabilities and provider.
    public static func tools(for capabilities: CapabilitySet, provider: AgentProvider? = nil) -> [IDETool] {
        allTools.filter { tool in
            switch tool.visibility {
            case .polyfill(let capability, let providers):
                return !capabilities.contains(capability) || provider.map(providers.contains) == true
            case .alwaysIDEOnly:
                return true
            }
        }
    }
}
