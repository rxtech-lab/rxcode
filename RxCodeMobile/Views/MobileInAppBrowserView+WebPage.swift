import Foundation
import Network
import os.log
import RxCodeCore
import RxCodeSync
import SwiftUI
import WebKit
import _WebKit_SwiftUI

extension MobileInAppBrowserView {
    static func makeWebPage(proxyInfo: MobileWebProxyInfo?) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = websiteDataStore(proxyInfo: proxyInfo)
        return WebPage(configuration: configuration)
    }

    private static func websiteDataStore(proxyInfo: MobileWebProxyInfo?) -> WKWebsiteDataStore {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        guard let proxyInfo,
              let port = UInt16(exactly: proxyInfo.port)
        else {
            Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileInAppBrowser")
                .warning("[WebBrowserSync] webview proxy disabled: missing proxy info")
            return dataStore
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxyInfo.host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        var proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
        proxy.matchDomains = ["localhost", "127.0.0.1", "0.0.0.0"]
        proxy.allowFailover = false
        proxy.applyCredential(username: proxyInfo.username, password: proxyInfo.password)
        dataStore.proxyConfigurations = [proxy]
        Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileInAppBrowser")
            .info("[WebBrowserSync] webview proxy configured host=\(proxyInfo.host, privacy: .public) port=\(proxyInfo.port, privacy: .public)")
        return dataStore
    }
}
