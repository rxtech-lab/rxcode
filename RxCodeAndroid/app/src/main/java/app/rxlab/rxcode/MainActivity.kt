package app.rxlab.rxcode

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import app.rxlab.rxcode.pairing.PairingToken
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.ui.RxCodeApp
import app.rxlab.rxcode.ui.theme.RxCodeTheme
import app.rxlab.rxcode.ui.util.hideKeyboardOnUserScroll
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private var pendingDeeplink by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.w(TAG, "MainActivity.onCreate data=${intent?.dataString?.let { "present" } ?: "none"}")
        enableEdgeToEdge()
        pendingDeeplink = intent?.dataString
        setContent {
            RxCodeTheme {
                val vm: MobileAppState = hiltViewModel()
                val state by vm.state.collectAsState()
                val lifecycle = LocalLifecycleOwner.current.lifecycle
                LaunchedEffect(vm) { vm.start() }
                DisposableEffect(vm, lifecycle) {
                    val observer = LifecycleEventObserver { _, event ->
                        when (event) {
                            Lifecycle.Event.ON_START -> vm.handleAppForeground()
                            Lifecycle.Event.ON_STOP -> vm.handleAppBackground()
                            else -> Unit
                        }
                    }
                    lifecycle.addObserver(observer)
                    onDispose { lifecycle.removeObserver(observer) }
                }
                LaunchedEffect(pendingDeeplink) {
                    pendingDeeplink?.let { url ->
                        PairingToken.parseOrNull(url)?.let(vm::beginPairing)
                        pendingDeeplink = null
                    }
                }
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .hideKeyboardOnUserScroll(),
                ) {
                    RxCodeApp(state = state, viewModel = vm)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.w(TAG, "MainActivity.onNewIntent data=${intent.dataString?.let { "present" } ?: "none"}")
        intent.dataString?.let { pendingDeeplink = it }
    }

    private companion object {
        private const val TAG = "RxCodeStartup"
    }
}
