import ExtensionKit
import SwiftUI

struct SystemExtensionBrowser: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> EXAppExtensionBrowserViewController {
        EXAppExtensionBrowserViewController()
    }

    func updateNSViewController(_ controller: EXAppExtensionBrowserViewController, context: Context) {}
}
