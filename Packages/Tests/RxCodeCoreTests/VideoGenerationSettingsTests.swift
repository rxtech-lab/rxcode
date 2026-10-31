import XCTest
@testable import RxCodeCore

final class VideoGenerationSettingsTests: XCTestCase {
    func testPresetSelectionAndCustomRoundTrip() {
        var settings = VideoGenerationSettings()
        for (quality, width, height, steps) in [
            (VideoGenerationSettings.Quality.low, 640, 384, 4),
            (.medium, 896, 512, 12), (.high, 1280, 768, 24), (.ultra, 1536, 864, 40)
        ] {
            settings.select(quality)
            XCTAssertEqual(settings.width, width)
            XCTAssertEqual(settings.height, height)
            XCTAssertEqual(settings.steps, steps)
        }
        settings.select(.custom)
        settings.seed = 123
        XCTAssertEqual(settings.width, 1536)
        XCTAssertEqual(VideoGenerationSettings.decode(settings.encoded), settings)
    }

    func testInvalidStorageAndBounds() {
        XCTAssertEqual(VideoGenerationSettings.decode("invalid"), .init())
        var settings = VideoGenerationSettings()
        settings.width = 99999
        settings.height = 511
        settings.frames = 30
        settings.steps = 0
        settings.fps = -1
        settings.seed = -9
        let result = settings.validated
        XCTAssertEqual(result.width, 1920)
        XCTAssertEqual(result.height, 480)
        XCTAssertEqual(result.frames, 25)
        XCTAssertEqual(result.steps, 1)
        XCTAssertEqual(result.fps, 1)
        XCTAssertEqual(result.seed, -1)
    }
}
