#if !SWIFT_PACKAGE
import ExtensionFoundation
import RxCodeExtensionSDK

@main struct Contributor: AppExtension {
    var configuration: some AppExtensionConfiguration {
        ExtensionService.configuration(scenes: [], test: { $0 }) { integration, host in
            try await TursoUsage.fetch(integration, host: host, now: .now)
        }
    }
}
#endif
