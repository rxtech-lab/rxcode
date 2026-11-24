#if !SWIFT_PACKAGE
import ExtensionFoundation
import ExtensionKit
import RxCodeExtensionSDK
import SwiftUI

@main
struct Contributor: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            extensionAccountSettingsScene { try await CloudflareAccounts.list(host: $0) },
            configuration: ExtensionService.configuration(scenes: ["settings"], test: { $0 }) { integration, host in
                try await CloudflareUsage.fetch(integration, host: host, now: .now)
            }
        )
    }
}
#endif
