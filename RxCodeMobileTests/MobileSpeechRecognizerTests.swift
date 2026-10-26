import Speech
import XCTest
@testable import RxCodeMobile

@MainActor
final class MobileSpeechRecognizerTests: XCTestCase {
    func testCanceledStartDoesNotRequestPermission() async {
        var permissionRequested = false
        let speech = MobileSpeechRecognizer(
            authorizeSpeech: { permissionRequested = true; return .authorized },
            authorizeMicrophone: { permissionRequested = true; return false }
        )
        let pendingStart = Task { await speech.start(localeIdentifier: "en-US") }
        pendingStart.cancel()
        await pendingStart.value
        XCTAssertFalse(permissionRequested)
        XCTAssertEqual(speech.phase, .idle)
    }

    func testDeniedSpeechPermissionDoesNotRequestMicrophone() async {
        var microphoneRequested = false
        let speech = MobileSpeechRecognizer(
            authorizeSpeech: { .denied },
            authorizeMicrophone: { microphoneRequested = true; return true }
        )
        await speech.start(localeIdentifier: "en-US")
        XCTAssertFalse(microphoneRequested)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertTrue(speech.needsSettings)
        XCTAssertNotNil(speech.errorMessage)
    }

    func testDeniedMicrophonePermissionPreservesDraft() async {
        let speech = MobileSpeechRecognizer(authorizeSpeech: { .authorized }, authorizeMicrophone: { false })
        speech.transcript = "Existing dictation"
        await speech.start(localeIdentifier: "en-US")
        XCTAssertEqual(speech.transcript, "Existing dictation")
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertTrue(speech.needsSettings)
        XCTAssertNotNil(speech.errorMessage)
    }

    func testCancelWhileAuthorizingRejectsLatePermissionResult() async {
        var permission: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
        var microphoneRequested = false
        let speech = MobileSpeechRecognizer(
            authorizeSpeech: { await withCheckedContinuation { permission = $0 } },
            authorizeMicrophone: { microphoneRequested = true; return true }
        )
        let pendingStart = Task { await speech.start(localeIdentifier: "en-US") }
        while permission == nil { await Task.yield() }
        XCTAssertEqual(speech.phase, .authorizing)
        speech.cancel()
        permission?.resume(returning: .authorized)
        await pendingStart.value
        XCTAssertFalse(microphoneRequested)
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertNil(speech.errorMessage)
    }

    func testInterruptWhileRequestingMicrophoneRejectsLateDenial() async {
        var permission: CheckedContinuation<Bool, Never>?
        let speech = MobileSpeechRecognizer(
            authorizeSpeech: { .authorized },
            authorizeMicrophone: { await withCheckedContinuation { permission = $0 } }
        )
        speech.transcript = "Keep this text"
        let pendingStart = Task { await speech.start(localeIdentifier: "en-US") }
        while permission == nil { await Task.yield() }
        speech.interrupt()
        permission?.resume(returning: false)
        await pendingStart.value
        XCTAssertEqual(speech.phase, .idle)
        XCTAssertEqual(speech.transcript, "Keep this text")
        XCTAssertNil(speech.errorMessage)
        XCTAssertTrue(speech.levels.allSatisfy { $0 == 0 })
    }
}
