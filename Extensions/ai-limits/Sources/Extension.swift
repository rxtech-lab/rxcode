#if !SWIFT_PACKAGE
import ExtensionFoundation
import ExtensionKit
import RxCodeExtensionSDK

@main
struct Contributor: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            extensionUsageDetailScene(load: AILimitsProvider.reports) { report, metric in
                LimitDetail(reports: report, metric: metric)
            },
            configuration: ExtensionService.configuration(scenes: ["usage-detail"], test: { $0 }, fetchUsage: AILimitsProvider.fetch)
        )
    }
}
#endif
