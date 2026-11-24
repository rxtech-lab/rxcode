#if !SWIFT_PACKAGE
import ExtensionFoundation
import RxCodeExtensionSDK

@main
struct Contributor: AppExtension {
    var configuration: some AppExtensionConfiguration {
        ExtensionService.configuration(scenes: [], test: { $0 }, fetchUsage: AntigravityProvider.fetch)
    }
}
#endif
