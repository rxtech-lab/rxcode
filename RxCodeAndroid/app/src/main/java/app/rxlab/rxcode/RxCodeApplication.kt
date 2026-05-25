package app.rxlab.rxcode

import android.app.Application
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.crashlytics.FirebaseCrashlytics
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class RxCodeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Log.w(TAG, "RxCodeApplication launched")
        // FirebaseApp.initializeApp is a no-op when google-services.json is absent
        // (e.g. local dev without secrets); both calls return null gracefully then.
        if (FirebaseApp.initializeApp(this) != null) {
            FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = true
        } else {
            Log.w(TAG, "Firebase not configured — skipping analytics/crashlytics init")
        }
    }

    private companion object {
        private const val TAG = "RxCodeStartup"
    }
}
