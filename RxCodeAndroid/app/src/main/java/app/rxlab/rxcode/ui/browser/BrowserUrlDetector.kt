package app.rxlab.rxcode.ui.browser

import android.net.Uri
import app.rxlab.rxcode.proto.MobileWebProxyInfo

/**
 * Mirrors iOS `MobileBrowserURLDetector`. The desktop publishes an HTTP proxy
 * (host/port + basic-auth) in every snapshot; on mobile we route requests to
 * that proxy and additionally rewrite localhost dev-server URLs through the
 * desktop's `/__rxcode_browser` bootstrap so the WebView lands on the right
 * origin even when it can't reach `127.0.0.1` directly.
 */
object BrowserUrlDetector {
    private val URL_REGEX = Regex("""https?://[^\s<>"')\]]+""")

    fun detect(texts: List<String>): String? {
        val candidates = texts.asReversed().flatMap { text ->
            URL_REGEX.findAll(text).map { match ->
                match.value.trimEnd('.', ',', ';', ':', '!', '?')
            }
        }
        return candidates.firstOrNull(::isLocalDevURL) ?: candidates.firstOrNull()
    }

    fun isLocalDevURL(url: String): Boolean {
        val host = runCatching { Uri.parse(url).host?.lowercase() }.getOrNull() ?: return false
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    /**
     * Wrap a localhost dev URL in the desktop's reverse-proxy bootstrap. The
     * bootstrap rewrites links/forms so the user can browse same-origin pages
     * without leaving the proxy domain.
     */
    fun desktopProxyBootstrapURL(url: String, proxyInfo: MobileWebProxyInfo?): String {
        if (proxyInfo == null || !isLocalDevURL(url)) return url
        val parsed = runCatching { Uri.parse(url) }.getOrNull() ?: return url
        if (parsed.scheme?.lowercase() != "http") return url
        return Uri.Builder()
            .scheme("http")
            .encodedAuthority("${proxyInfo.host}:${proxyInfo.port}")
            .path("/__rxcode_browser")
            .appendQueryParameter("target", url)
            .appendQueryParameter("token", proxyInfo.password)
            .build()
            .toString()
    }

    /** Reverse of [desktopProxyBootstrapURL] — strip the proxy wrapper. */
    fun userFacingURL(current: String, proxyInfo: MobileWebProxyInfo?): String {
        if (proxyInfo == null) return current
        val parsed = runCatching { Uri.parse(current) }.getOrNull() ?: return current
        if (parsed.host != proxyInfo.host || parsed.port != proxyInfo.port) return current
        if (parsed.path == "/__rxcode_browser") {
            return parsed.getQueryParameter("target") ?: current
        }
        return current
    }
}
