import ExtensionFoundation
import ExtensionKit
import FixtureWire
import SwiftUI

@main
struct SidebarExtension: AppExtension {
    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            PrimitiveAppExtensionScene(id: Probe.scene) {
                Text("RxCode fixture sidebar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } onConnection: { FixtureService.accept($0) },
            configuration: ConnectionHandler { FixtureService.accept($0) }
        )
    }
}
