import Foundation
import Network
import os.log
import RxCodeCore
import RxCodeSync
import SwiftUI
import WebKit
import _WebKit_SwiftUI

enum MobileBrowserURLDetector {
    static func detect(in texts: [String]) -> URL? {
        let candidates = texts.reversed().flatMap(extractURLs)
        return candidates.first(where: isLocalDevURL) ?? candidates.first
    }

    private nonisolated static func extractURLs(from text: String) -> [URL] {
        let pattern = #"https?://[^\s<>"')\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            return URL(string: raw)
        }
    }

    nonisolated static func isLocalDevURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    nonisolated static func desktopProxyBootstrapURL(for url: URL, proxyInfo: MobileWebProxyInfo?) -> URL {
        guard let proxyInfo,
              isLocalDevURL(url),
              url.scheme?.lowercased() == "http"
        else {
            return url
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = proxyInfo.host
        components.port = proxyInfo.port
        components.path = "/__rxcode_browser"
        components.queryItems = [
            URLQueryItem(name: "target", value: url.absoluteString),
            URLQueryItem(name: "token", value: proxyInfo.password)
        ]
        return components.url ?? url
    }

    nonisolated static func userFacingURL(
        for url: URL,
        currentDisplayURL: URL?,
        proxyInfo: MobileWebProxyInfo?
    ) -> URL {
        if let bootstrapTarget = reverseBootstrapTargetURL(for: url, proxyInfo: proxyInfo) {
            return bootstrapTarget
        }

        guard isProxyURL(url, proxyInfo: proxyInfo),
              let displayOrigin = currentDisplayURL.flatMap(originURL(for:)),
              isLocalDevURL(displayOrigin)
        else {
            return url
        }

        var components = URLComponents(url: displayOrigin, resolvingAgainstBaseURL: false)
        let proxyComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let proxyPath = proxyComponents?.percentEncodedPath ?? url.path
        components?.percentEncodedPath = proxyPath.isEmpty ? "/" : proxyPath
        components?.percentEncodedQuery = proxyComponents?.percentEncodedQuery
        components?.percentEncodedFragment = proxyComponents?.percentEncodedFragment
        return components?.url ?? displayOrigin
    }

    private nonisolated static func reverseBootstrapTargetURL(for url: URL, proxyInfo: MobileWebProxyInfo?) -> URL? {
        guard let proxyInfo,
              url.host == proxyInfo.host,
              url.port == proxyInfo.port,
              url.path == "/__rxcode_browser",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "target" })?.value,
              let targetURL = URL(string: target)
        else {
            return nil
        }
        return targetURL
    }

    private nonisolated static func isProxyURL(_ url: URL, proxyInfo: MobileWebProxyInfo?) -> Bool {
        guard let proxyInfo else { return false }
        return url.host == proxyInfo.host && url.port == proxyInfo.port
    }

    private nonisolated static func originURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url
    }
}

struct MobileInAppBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let proxyInfo: MobileWebProxyInfo?
    private let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "MobileInAppBrowser")
    @State private var addressText: String
    @State private var loadedURL: URL?
    @State private var displayedURL: URL?
    @State private var webPage: WebPage
    @State private var errorText: String?
    @State private var isAddressEditing = false
    @State private var isBottomAddressCollapsed = false
    @State private var didTriggerPullRefresh = false
    @State private var pageBackgroundColor: Color = Color(.systemBackground)
    @FocusState private var isAddressFocused: Bool

    init(initialURL: URL?, proxyInfo: MobileWebProxyInfo?) {
        self.proxyInfo = proxyInfo
        _addressText = State(initialValue: initialURL?.absoluteString ?? "")
        _loadedURL = State(initialValue: initialURL.map {
            MobileBrowserURLDetector.desktopProxyBootstrapURL(for: $0, proxyInfo: proxyInfo)
        })
        _displayedURL = State(initialValue: initialURL)
        _webPage = State(initialValue: Self.makeWebPage(proxyInfo: proxyInfo))
    }

    var body: some View {
        GeometryReader { geometry in
            let contentInsets = webContentPadding(safeArea: geometry.safeAreaInsets)

            ZStack {
                // Fills the screen behind the web view so the status bar strip
                // and the area behind the floating address bar take on the
                // page color — matching Safari.
                pageBackgroundColor
                    .ignoresSafeArea()

                browserSurface(insets: contentInsets)

                if loadedURL == nil {
                    startSurface
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                browserChrome(safeArea: geometry.safeAreaInsets)
            }
            .background(Color(.systemBackground))
            .ignoresSafeArea()
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isAddressEditing)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: loadedURL == nil)
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: isBottomAddressCollapsed)
            .animation(.easeOut(duration: 0.25), value: pageBackgroundColor)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await observePageNavigations()
        }
        .onAppear {
            AnalyticsService.shared.log(.inAppBrowserOpened, parameters: [
                "has_proxy": proxyInfo != nil,
                "host": loadedURL?.host ?? "",
            ])
            guard let loadedURL, webPage.url == nil else { return }
            logger.info("[WebBrowserSync] webview initial load url=\(loadedURL.absoluteString, privacy: .public) hasProxy=\((proxyInfo != nil), privacy: .public)")
            webPage.load(loadedURL)
        }
        .onChange(of: webPage.url) { _, url in
            guard let url else { return }
            displayedURL = MobileBrowserURLDetector.userFacingURL(
                for: url,
                currentDisplayURL: displayedURL,
                proxyInfo: proxyInfo
            )
        }
        .onChange(of: webPage.isLoading) { _, isLoading in
            guard !isLoading else { return }
            Task { await refreshPageBackgroundColor() }
        }
        .alert("Browser Error", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private func browserSurface(insets: EdgeInsets) -> some View {
        if loadedURL == nil {
            Color.clear
        } else {
            WebView(webPage)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewContentBackground(.visible)
                .webViewOnScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { oldY, newY in
                    updateBrowserChromeForScroll(oldY: oldY, newY: newY)
                }
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
                .ignoresSafeArea(edges: .horizontal)
        }
    }

    /// Frame padding that keeps the web view between the status bar and the
    /// floating address bar. The new SwiftUI `WebView` does not honor scroll
    /// content insets — `contentMargins`, `safeAreaInset` and `safeAreaPadding`
    /// are all ignored — so the web view frame itself must be inset. The status
    /// bar strip left above the web view is filled with `pageBackgroundColor`
    /// to match Safari.
    private func webContentPadding(safeArea: EdgeInsets) -> EdgeInsets {
        guard loadedURL != nil else {
            return EdgeInsets()
        }

        if horizontalSizeClass == .regular {
            // iPad: reserve the status bar + the floating top chrome bar.
            // `iPadChrome`: .padding(.top, safeArea.top + 10), .padding(.vertical, 10)
            // around a 48pt-tall address field.
            let topBarHeight: CGFloat = 48 + 20
            return EdgeInsets(
                top: safeArea.top + 10 + topBarHeight + 10,
                leading: 0,
                bottom: safeArea.bottom,
                trailing: 0
            )
        }

        // iPhone: reserve the status bar at the top and the floating address
        // bar at the bottom. A constant (expanded) address bar height is used
        // so the web view does not reflow when the bar collapses on scroll.
        // `addressDisplayBar`: capsule height 46 (expanded), placed with
        // `.padding(.bottom, safeArea.bottom + 18)` in `iPhoneChrome`.
        let expandedAddressBarHeight: CGFloat = 46
        return EdgeInsets(
            top: safeArea.top,
            leading: 0,
            bottom: safeArea.bottom + 18 + expandedAddressBarHeight + 8,
            trailing: 0
        )
    }

    private var startSurface: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                favoritesSection
                privacyReport
                Spacer(minLength: 180)
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 44 : 16)
            .padding(.top, horizontalSizeClass == .regular ? 96 : 88)
            .frame(maxWidth: horizontalSizeClass == .regular ? 760 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground).opacity(0.96))
        .ignoresSafeArea()
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Favorites", systemImage: "person.fill")
                .font(.largeTitle.weight(.bold))

            HStack(spacing: 22) {
                favoriteButton(title: "Apple", systemImage: "apple.logo", url: "https://apple.com")
                favoriteButton(title: "Bing", systemImage: "b.circle.fill", url: "https://bing.com")
                favoriteButton(title: "Google", systemImage: "g.circle.fill", url: "https://google.com")
                favoriteButton(title: "Yahoo", systemImage: "y.circle.fill", url: "https://yahoo.com")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var privacyReport: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Privacy Report")
                .font(.title.weight(.bold))

            HStack(spacing: 18) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 24, weight: .semibold))
                Text("RxCode keeps this browser session separate from your regular Safari data.")
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26, style: .continuous))
        }
    }

    private func favoriteButton(title: String, systemImage: String, url: String) -> some View {
        Button {
            MobileHaptics.buttonTap()
            addressText = url
            loadAddress()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 72, height: 72)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 82)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func browserChrome(safeArea: EdgeInsets) -> some View {
        if horizontalSizeClass == .regular {
            iPadChrome(safeArea: safeArea)
        } else {
            iPhoneChrome(safeArea: safeArea)
        }
    }

    private func iPadChrome(safeArea: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                glassIconButton("xmark", action: closeBrowser)

                glassIconButton("chevron.backward", isEnabled: canGoBack) {
                    goBack()
                }

                glassIconButton("chevron.forward", isEnabled: canGoForward) {
                    goForward()
                }

                addressField(isCompact: true)
                    .frame(maxWidth: 620)

                glassIconButton(isLoading ? "xmark" : "arrow.clockwise", isEnabled: loadedURL != nil) {
                    reloadOrStop()
                }

                browserMenu()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28, style: .continuous))
            .padding(.top, safeArea.top + 10)
            .padding(.horizontal, 24)

            Spacer()
        }
    }

    private func iPhoneChrome(safeArea: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                glassIconButton("xmark", action: closeBrowser)
            }
            .padding(.top, safeArea.top + 8)
            .padding(.horizontal, 18)

            Spacer()

            if isAddressEditing || loadedURL == nil {
                HStack(spacing: 8) {
                    addressField(isCompact: false)

                    glassIconButton("xmark", size: 44) {
                        if loadedURL == nil {
                            closeBrowser()
                        } else {
                            cancelAddressEditing()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, safeArea.bottom + 18)
            } else {
                HStack(spacing: 8) {
                    if !isBottomAddressCollapsed {
                        glassIconButton("chevron.left", size: 46, isEnabled: canGoBack) {
                            goBack()
                        }
                    } else {
                        Spacer(minLength: 0)
                    }

                    addressDisplayBar

                    if !isBottomAddressCollapsed {
                        browserMenu(size: 46)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, safeArea.bottom + 18)
            }
        }
    }

    private var addressDisplayBar: some View {
        HStack(spacing: 10) {
            Button {
                beginAddressEditing()
            } label: {
                HStack(spacing: 10) {
                    if !isBottomAddressCollapsed {
                        Image(systemName: "globe")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(isBottomAddressCollapsed ? collapsedDisplayTitle : displayTitle)
                        .font(.system(size: isBottomAddressCollapsed ? 14 : 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isBottomAddressCollapsed {
                Button {
                    MobileHaptics.buttonTap()
                    reloadOrStop()
                } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, isBottomAddressCollapsed ? 12 : 14)
        .frame(width: isBottomAddressCollapsed ? 170 : nil, height: isBottomAddressCollapsed ? 40 : 46)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay(alignment: .bottom) {
            addressLoadingProgressBar
        }
    }

    private func addressField(isCompact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search or enter website name", text: $addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isAddressFocused)
                .onSubmit(loadAddress)
                .font(.system(size: isCompact ? 17 : 17, weight: .semibold))

            if !addressText.isEmpty {
                Button {
                    addressText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button("Go", action: loadAddress)
                .font(.system(size: isCompact ? 15 : 15, weight: .bold))
                .disabled(normalizedAddressURL == nil)
        }
        .padding(.horizontal, isCompact ? 14 : 14)
        .frame(height: isCompact ? 48 : 48)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay(alignment: .bottom) {
            addressLoadingProgressBar
        }
    }

    @ViewBuilder
    private var addressLoadingProgressBar: some View {
        if isLoading {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(10, proxy.size.width * CGFloat(clampedLoadingProgress)))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
            .padding(.bottom, 2)
            .transition(.opacity)
        }
    }

    private func browserMenu(size: CGFloat = 58) -> some View {
        Menu {
            Button {
                reloadOrStop()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(loadedURL == nil)

            Button(role: .cancel, action: closeBrowser) {
                Label("Close Browser", systemImage: "xmark")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size <= 48 ? 18 : 20, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }

    private func glassIconButton(
        _ systemName: String,
        size: CGFloat = 48,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            MobileHaptics.buttonTap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size <= 48 ? 17 : 21, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var normalizedAddressURL: URL? {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private func loadAddress() {
        guard let url = normalizedAddressURL else { return }
        let loadURL = MobileBrowserURLDetector.desktopProxyBootstrapURL(for: url, proxyInfo: proxyInfo)
        addressText = url.absoluteString
        loadedURL = loadURL
        displayedURL = url
        isAddressEditing = false
        isAddressFocused = false
        isBottomAddressCollapsed = false
        webPage.load(loadURL)
        logger.info("[WebBrowserSync] load address url=\(url.absoluteString, privacy: .public) loadURL=\(loadURL.absoluteString, privacy: .public) hasProxy=\((proxyInfo != nil), privacy: .public)")
    }

    private var displayTitle: String {
        guard let url = currentDisplayURL ?? loadedURL else {
            return "Search"
        }

        if let host = url.host {
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }
        return url.absoluteString
    }

    private var collapsedDisplayTitle: String {
        let title = webPage.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? displayTitle : title
    }

    private func cancelAddressEditing() {
        addressText = currentDisplayURL?.absoluteString ?? addressText
        isAddressEditing = false
        isAddressFocused = false
    }

    private func beginAddressEditing() {
        MobileHaptics.buttonTap()
        addressText = currentDisplayURL?.absoluteString ?? addressText
        isBottomAddressCollapsed = false
        isAddressEditing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            isAddressFocused = true
        }
    }

    private func closeBrowser() {
        dismiss()
    }

    private var currentDisplayURL: URL? {
        guard let url = webPage.url else {
            return displayedURL
        }
        return MobileBrowserURLDetector.userFacingURL(
            for: url,
            currentDisplayURL: displayedURL,
            proxyInfo: proxyInfo
        )
    }

    private var canGoBack: Bool {
        webPage.backForwardList.backList.last != nil
    }

    private var canGoForward: Bool {
        webPage.backForwardList.forwardList.first != nil
    }

    private var isLoading: Bool {
        webPage.isLoading
    }

    private var clampedLoadingProgress: Double {
        min(max(webPage.estimatedProgress, 0.05), 1)
    }

    private func goBack() {
        guard let item = webPage.backForwardList.backList.last else { return }
        logger.info("[WebBrowserSync] webview command back canGoBack=true")
        webPage.load(item)
    }

    private func goForward() {
        guard let item = webPage.backForwardList.forwardList.first else { return }
        logger.info("[WebBrowserSync] webview command forward canGoForward=true")
        webPage.load(item)
    }

    private func reloadOrStop() {
        guard loadedURL != nil else { return }
        if webPage.isLoading {
            logger.info("[WebBrowserSync] webview command stop url=\(webPage.url?.absoluteString ?? "<nil>", privacy: .public)")
            webPage.stopLoading()
        } else {
            logger.info("[WebBrowserSync] webview command reload url=\(webPage.url?.absoluteString ?? "<nil>", privacy: .public)")
            webPage.reload()
        }
    }

    private func updateBrowserChromeForScroll(oldY: CGFloat, newY: CGFloat) {
        guard loadedURL != nil,
              horizontalSizeClass != .regular
        else {
            return
        }

        updatePullRefreshState(offsetY: newY)

        guard !isAddressEditing else { return }
        let delta = newY - oldY
        guard abs(delta) > 4 else { return }
        if delta > 0 {
            isBottomAddressCollapsed = true
        } else {
            isBottomAddressCollapsed = false
        }
    }

    private func updatePullRefreshState(offsetY: CGFloat) {
        if offsetY > -12 {
            didTriggerPullRefresh = false
        }

        guard offsetY < -88,
              !didTriggerPullRefresh,
              !webPage.isLoading
        else {
            return
        }

        didTriggerPullRefresh = true
        MobileHaptics.buttonTap()
        logger.info("[WebBrowserSync] pull refresh url=\(webPage.url?.absoluteString ?? "<nil>", privacy: .public)")
        webPage.reload()
    }

    /// Samples the loaded page's background color and uses it to fill the
    /// status bar strip above the web view, mirroring how Safari tints the
    /// status bar area with the page color.
    private func refreshPageBackgroundColor() async {
        guard loadedURL != nil else { return }
        let script = """
        const transparent = (c) => !c || c === 'transparent' || c === 'rgba(0, 0, 0, 0)';
        const bodyBg = document.body ? getComputedStyle(document.body).backgroundColor : null;
        if (!transparent(bodyBg)) { return bodyBg; }
        const htmlBg = document.documentElement ? getComputedStyle(document.documentElement).backgroundColor : null;
        return transparent(htmlBg) ? null : htmlBg;
        """
        do {
            let result = try await webPage.callJavaScript(script)
            guard let cssColor = result as? String,
                  let color = Self.parseCSSColor(cssColor)
            else {
                return
            }
            pageBackgroundColor = color
        } catch {
            logger.error("[WebBrowserSync] page color sampling failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Parses a CSS `rgb()` / `rgba()` color string into a SwiftUI `Color`.
    private static func parseCSSColor(_ string: String) -> Color? {
        let components = string
            .lowercased()
            .replacingOccurrences(of: "rgba", with: "")
            .replacingOccurrences(of: "rgb", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "(), /"))
            .filter { !$0.isEmpty }
        guard components.count >= 3,
              let red = Double(components[0]),
              let green = Double(components[1]),
              let blue = Double(components[2])
        else {
            return nil
        }
        let alpha = components.count >= 4 ? (Double(components[3]) ?? 1) : 1
        guard alpha > 0 else { return nil }
        return Color(
            .sRGB,
            red: red / 255,
            green: green / 255,
            blue: blue / 255,
            opacity: alpha
        )
    }

    private func observePageNavigations() async {
        do {
            for try await event in webPage.navigations {
                logger.info("[WebBrowserSync] navigation event=\(String(describing: event), privacy: .public) url=\(webPage.url?.absoluteString ?? "<nil>", privacy: .public)")
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("[WebBrowserSync] navigation failed url=\(webPage.url?.absoluteString ?? "<nil>", privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
        }
    }

    private static func makeWebPage(proxyInfo: MobileWebProxyInfo?) -> WebPage {
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
