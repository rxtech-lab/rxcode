import XCTest
@testable import RxCodeCore

final class StudioModelConfigTests: XCTestCase {
    private let reply = """
    Here is the form:
    ```json
    {"summary": "Turbo model: 8 steps, no guidance.",
     "parameters": [
       {"key": "steps", "label": "Steps", "control": "stepper", "min": 1, "max": 500, "step": 1, "default": 8},
       {"key": "guidance", "label": "Guidance", "control": "slider", "min": 0, "max": 2, "default": 1},
       {"key": "width", "label": "Width", "control": "choice", "options": [512, 1024], "default": 1024},
       {"key": "frames", "label": "Frames", "control": "stepper", "default": 25},
       {"key": "steps", "label": "Duplicate", "control": "stepper", "default": 4},
       {"key": "shell", "label": "Not a setting", "control": "text", "default": "rm"}
     ]}
    ```
    """

    func testParseKeepsOnlySupportedKeysAndClampsRanges() throws {
        let config = try XCTUnwrap(StudioModelConfig.parse(reply: reply, modelID: "m", kind: .image))
        // frames is video-only; the duplicate and unknown keys are dropped.
        XCTAssertEqual(config.parameters.map(\.key), [.steps, .guidance, .width])
        XCTAssertEqual(config.parameters[0].maximum, 150)
        XCTAssertEqual(config.parameters[0].defaultValue, .number(8))
        XCTAssertEqual(config.parameters[2].control, .choice)
        XCTAssertEqual(config.summary, "Turbo model: 8 steps, no guidance.")
    }

    func testParseRejectsRepliesWithoutUsableParameters() {
        XCTAssertNil(StudioModelConfig.parse(reply: "no json", modelID: "m", kind: .video))
        XCTAssertNil(StudioModelConfig.parse(reply: #"{"parameters":[{"key":"voice"}]}"#, modelID: "m", kind: .video))
    }

    func testAutoValuesAreFittedToTheForm() throws {
        let config = try XCTUnwrap(StudioModelConfig.parse(reply: reply, modelID: "m", kind: .image))
        let values = try XCTUnwrap(config.parseValues(reply: #"{"values":{"steps": 999, "guidance": 0.5, "width": 700, "fps": 30}}"#))
        XCTAssertEqual(values[.steps], .number(150))
        XCTAssertEqual(values[.guidance], .number(0.5))
        XCTAssertNil(values[.width], "700 is not one of the listed options")
        XCTAssertNil(values[.fps])
    }

    func testApplyingOverridesMakesSettingsCustom() {
        let image = ImageGenerationSettings().applying([.steps: .number(8), .guidance: .number(0), .width: .number(1024)])
        XCTAssertEqual(image.quality, .custom)
        XCTAssertEqual(image.steps(recommended: 30), 8)
        XCTAssertEqual(image.cfgScale(recommended: 4), 0)
        XCTAssertEqual(image.width, 1024)

        let audio = AudioGenerationSettings().applying([.voice: .text("nova"), .temperature: .number(0.2)])
        XCTAssertEqual(audio.voice, "nova")
        XCTAssertEqual(audio.delivery, .custom)

        XCTAssertEqual(VideoGenerationSettings().applying([:]), VideoGenerationSettings())
    }

    func testStorageRoundTripPreservesValuesAndMode() throws {
        var config = try XCTUnwrap(StudioModelConfig.parse(reply: reply, modelID: "m", kind: .image))
        config.values = [.steps: .number(12)]
        config.mode = .auto
        let decoded = StudioModelConfig.decodeAll(StudioModelConfig.encodeAll(["m": config]))["m"]
        XCTAssertEqual(decoded?.values, config.values)
        XCTAssertEqual(decoded?.mode, .auto)
        XCTAssertEqual(decoded?.resolvedValues[.steps], .number(12))
        XCTAssertEqual(decoded?.resolvedValues[.guidance], .number(1))
    }
}
