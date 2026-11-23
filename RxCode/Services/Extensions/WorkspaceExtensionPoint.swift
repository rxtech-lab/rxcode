import ExtensionFoundation

extension AppExtensionPoint {
    @Definition
    static var workspaceContributions: AppExtensionPoint {
        Name("workspace")
        Scope(restriction: .none)
        UserInterface(true)
    }
}

extension AppExtensionPoint {
    @Definition
    static var workspaceServices: AppExtensionPoint {
        Name("workspace-service")
        Scope(restriction: .none)
        UserInterface(false)
    }
}
