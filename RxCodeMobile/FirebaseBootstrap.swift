import FirebaseCore
import FirebaseCrashlytics
import Foundation
import os.log

enum FirebaseBootstrap {
    private static let logger = Logger(subsystem: "com.idealapp.RxCodeMobile", category: "Firebase")

    static func configure() {
        guard FirebaseApp.app() == nil else { return }
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            logger.warning("GoogleService-Info.plist not bundled — Firebase disabled")
            return
        }
        FirebaseApp.configure()
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        logger.info("Firebase configured")
    }
}
