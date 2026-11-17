import RxCodeCore
import Testing
@testable import RxCode

@MainActor
struct PetVoicePresetsTests {
    private func config(voices: [String], defaultVoice: String) -> StudioModelConfig {
        StudioModelConfig(
            modelID: "mlx-community/Some-TTS",
            kind: .audio,
            parameters: [
                StudioParameter(
                    key: .voice,
                    label: "Speaker",
                    control: .choice,
                    options: voices.map { .text($0) },
                    defaultValue: .text(defaultVoice)
                ),
            ]
        )
    }

    @Test func readmeVoicesBecomeOptions() {
        let config = config(voices: ["Vivian", "Ryan", "Serena"], defaultVoice: "Ryan")
        let options = PetVoicePresets.options(modelID: "mlx-community/Some-TTS", config: config)
        #expect(options?.map(\.id) == ["Vivian", "Ryan", "Serena"])
        #expect(PetVoicePresets.defaultVoice(modelID: "mlx-community/Some-TTS", config: config) == "Ryan")
    }

    @Test func readmeVoicesOverrideKokoroFallback() {
        let config = config(voices: ["af_sky"], defaultVoice: "af_sky")
        let options = PetVoicePresets.options(modelID: "mlx-community/Kokoro-82M-bf16", config: config)
        #expect(options?.map(\.id) == ["af_sky"])
    }

    @Test func kokoroFallsBackToBuiltInPresets() {
        let options = PetVoicePresets.options(modelID: "mlx-community/Kokoro-82M-bf16", config: nil)
        #expect(options?.contains { $0.id == "af_heart" } == true)
    }

    @Test func unknownModelWithoutReadmeHasNoOptions() {
        #expect(PetVoicePresets.options(modelID: "someone/Other-TTS", config: nil) == nil)
        #expect(PetVoicePresets.defaultVoice(modelID: "someone/Other-TTS", config: nil) == nil)
    }
}
