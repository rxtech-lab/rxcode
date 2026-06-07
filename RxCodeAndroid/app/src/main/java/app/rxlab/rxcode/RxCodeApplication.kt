package app.rxlab.rxcode

import android.app.Application
import android.util.Log
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.decode.SvgDecoder
import app.rxlab.rxcode.ui.util.CodeHighlighter
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class RxCodeApplication : Application(), ImageLoaderFactory {
    override fun onCreate() {
        super.onCreate()
        Log.w(TAG, "RxCodeApplication launched")
        // Load the tree-sitter native library once. If it fails (unexpected ABI,
        // missing .so), syntax highlighting silently falls back to plain text.
        CodeHighlighter.initialize(this)
        // FirebaseApp.initializeApp is a no-op when google-services.json is absent
        // (e.g. local dev without secrets); both calls return null gracefully then.
        if (FirebaseApp.initializeApp(this) != null) {
            FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = true
        } else {
            Log.w(TAG, "Firebase not configured — skipping analytics/crashlytics init")
        }
    }

    // ACP registry icons (and some autopilot avatars) are served as SVGs, which
    // Android's native ImageDecoder can't handle ("Failed to create image decoder
    // … 'unimplemented'"). Register Coil's SvgDecoder on the app-wide ImageLoader so
    // every AsyncImage can render them.
    override fun newImageLoader(): ImageLoader =
        ImageLoader.Builder(this)
            .components { add(SvgDecoder.Factory()) }
            .build()

    private companion object {
        private const val TAG = "RxCodeStartup"
    }
}
