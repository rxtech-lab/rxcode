import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation
import RxCodeCore
import os.log

enum FirebaseBootstrap {
    private static let logger = Logger(subsystem: "com.idealapp.RxCode", category: "Firebase")

    static func configure() {
        if FirebaseApp.app() == nil {
            guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
                logger.warning("GoogleService-Info.plist not bundled — Firebase disabled")
                return
            }
            FirebaseApp.configure()
            logger.info("Firebase configured")
        }
        // Quiet Firebase's own console chatter. The startup I-COR000003 /
        // I-SES000000 pair is emitted from framework +load methods that run
        // before any app code, so it can't be suppressed; this at least keeps
        // the rest of the session clean.
        FirebaseConfiguration.shared.setLoggerLevel(.error)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        installAnalyticsHandler()
    }

    private static func installAnalyticsHandler() {
        AnalyticsService.shared.install { name, parameters in
            Analytics.logEvent(name, parameters: parameters)
        }
    }
}
