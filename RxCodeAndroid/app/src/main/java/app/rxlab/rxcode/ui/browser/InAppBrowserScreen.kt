package app.rxlab.rxcode.ui.browser

import android.annotation.SuppressLint
import android.os.Build
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import app.rxlab.rxcode.proto.MobileWebProxyInfo
import java.net.URLEncoder
import java.util.concurrent.Executor

/**
 * Full-screen WebView wrapper used by the chat-detail "Open in Browser"
 * action. Mirrors the iOS `MobileInAppBrowserView`: address bar with the
 * user-facing URL (proxy wrapper hidden), reload + close affordances, and a
 * bottom progress bar. The desktop's `MobileWebProxyInfo` is installed via
 * AndroidX `ProxyController` so localhost dev servers running on the Mac are
 * reachable from the phone.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun InAppBrowserScreen(
    initialUrl: String?,
    proxyInfo: MobileWebProxyInfo?,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val initialLoaded = remember(initialUrl, proxyInfo) {
        initialUrl?.let { BrowserUrlDetector.desktopProxyBootstrapURL(it, proxyInfo) }
    }
    var addressText by remember(initialUrl) { mutableStateOf(initialUrl.orEmpty()) }
    var loadingProgress by remember { mutableStateOf(0) }
    var isLoading by remember { mutableStateOf(false) }
    var lastError by remember { mutableStateOf<String?>(null) }
    var pendingLoad by remember { mutableStateOf<String?>(initialLoaded) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    val scope = rememberCoroutineScope()

    InstallWebProxy(proxyInfo)

    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxSize()) {
            BrowserTopBar(
                addressText = addressText,
                onAddressChange = { addressText = it },
                onSubmit = {
                    val target = normalizeAddress(addressText)
                    val routed = BrowserUrlDetector.desktopProxyBootstrapURL(target, proxyInfo)
                    pendingLoad = routed
                    webView?.loadUrl(routed)
                },
                onReload = { webView?.reload() },
                onClose = onDismiss,
                modifier = Modifier
                    .statusBarsPadding()
                    .fillMaxWidth(),
            )
            if (isLoading) {
                LinearProgressIndicator(
                    progress = { loadingProgress / 100f },
                    modifier = Modifier.fillMaxWidth().height(2.dp),
                )
            }
            Box(Modifier.weight(1f)) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        WebView(ctx).apply {
                            layoutParams = ViewGroup.LayoutParams(
                                ViewGroup.LayoutParams.MATCH_PARENT,
                                ViewGroup.LayoutParams.MATCH_PARENT,
                            )
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            settings.useWideViewPort = true
                            settings.loadWithOverviewMode = true
                            settings.setSupportZoom(true)
                            settings.builtInZoomControls = true
                            settings.displayZoomControls = false
                            webViewClient = object : WebViewClient() {
                                override fun shouldOverrideUrlLoading(
                                    view: WebView?,
                                    request: WebResourceRequest?,
                                ): Boolean = false

                                override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                                    isLoading = true
                                    lastError = null
                                    url?.let {
                                        addressText = BrowserUrlDetector.userFacingURL(it, proxyInfo)
                                    }
                                }

                                override fun onPageFinished(view: WebView?, url: String?) {
                                    isLoading = false
                                    url?.let {
                                        addressText = BrowserUrlDetector.userFacingURL(it, proxyInfo)
                                    }
                                }

                                override fun onReceivedHttpAuthRequest(
                                    view: WebView?,
                                    handler: android.webkit.HttpAuthHandler?,
                                    host: String?,
                                    realm: String?,
                                ) {
                                    if (proxyInfo != null && host == proxyInfo.host) {
                                        handler?.proceed(proxyInfo.username, proxyInfo.password)
                                    } else {
                                        handler?.cancel()
                                    }
                                }
                            }
                            webChromeClient = object : WebChromeClient() {
                                override fun onProgressChanged(view: WebView?, newProgress: Int) {
                                    loadingProgress = newProgress
                                }
                            }
                            webView = this
                            pendingLoad?.let { loadUrl(it); pendingLoad = null }
                        }
                    },
                )
                if (initialLoaded == null) {
                    EmptyBrowserState()
                }
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose { webView?.destroy() }
    }
    LaunchedEffect(initialLoaded) {
        if (initialLoaded != null && webView != null && pendingLoad != null) {
            webView?.loadUrl(initialLoaded)
            pendingLoad = null
        }
    }
}

@Composable
private fun BrowserTopBar(
    addressText: String,
    onAddressChange: (String) -> Unit,
    onSubmit: () -> Unit,
    onReload: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(modifier = modifier, color = MaterialTheme.colorScheme.surface, tonalElevation = 2.dp) {
        Row(
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            IconButton(onClick = onClose) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Close")
            }
            TextField(
                value = addressText,
                onValueChange = onAddressChange,
                singleLine = true,
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp),
                shape = RoundedCornerShape(22.dp),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri,
                    imeAction = ImeAction.Go,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrect = false,
                ),
                keyboardActions = KeyboardActions(onGo = { onSubmit() }),
            )
            IconButton(onClick = onReload) {
                Icon(Icons.Outlined.Refresh, contentDescription = "Reload")
            }
        }
    }
}

@Composable
private fun EmptyBrowserState() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Type a URL to open", style = MaterialTheme.typography.titleMedium)
            Text(
                "Localhost dev servers running on your Mac are routed through the paired desktop's proxy.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * Installs the desktop's HTTP proxy on the WebView via AndroidX
 * [ProxyController]. The controller targets the global WebView process — we
 * scope its lifetime to the composition so the proxy is removed when the
 * browser dismisses. Falls back to direct connection on devices that lack
 * `WebViewFeature.PROXY_OVERRIDE` support.
 */
@Composable
private fun InstallWebProxy(proxyInfo: MobileWebProxyInfo?) {
    DisposableEffect(proxyInfo) {
        if (proxyInfo != null && WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            val executor = Executor { it.run() }
            val config = ProxyConfig.Builder()
                .addProxyRule("${proxyInfo.host}:${proxyInfo.port}")
                .addDirect()
                .build()
            ProxyController.getInstance().setProxyOverride(config, executor, {})
        }
        onDispose {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
                runCatching { ProxyController.getInstance().clearProxyOverride({ it.run() }, {}) }
            }
        }
    }
}

private fun normalizeAddress(input: String): String {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return trimmed
    if (trimmed.contains("://")) return trimmed
    if (trimmed.contains(' ') || !trimmed.contains('.')) {
        return "https://www.google.com/search?q=" +
            URLEncoder.encode(trimmed, Charsets.UTF_8.name())
    }
    return "https://$trimmed"
}
