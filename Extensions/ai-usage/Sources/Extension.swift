#if !SWIFT_PACKAGE
import ExtensionFoundation
import ExtensionKit
import RxCodeExtensionSDK

@main
struct Contributor: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            extensionUsageDetailScene(load: AIUsageProvider.report) { report, metric in
                UsageDetail(report: report, metric: metric)
            },
            configuration: ExtensionService.configuration(scenes: ["usage-detail"], test: { $0 }, fetchUsage: AIUsageProvider.fetch)
        )
    }
}
#endif
