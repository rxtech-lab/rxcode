package app.rxlab.rxcode

import android.app.Application
import android.util.Log
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class RxCodeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Log.w(TAG, "RxCodeApplication launched")
    }

    private companion object {
        private const val TAG = "RxCodeStartup"
    }
}
