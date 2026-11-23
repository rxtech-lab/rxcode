import ExtensionFoundation

@main
struct ServiceExtension: AppExtension {
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler { FixtureService.accept($0) }
    }
}
