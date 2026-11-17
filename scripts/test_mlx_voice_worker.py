"""Run with the MLX audio runtime's Python (requires numpy, no model download)."""

import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest


spec = importlib.util.spec_from_file_location(
    "mlx_voice_worker", Path(__file__).resolve().parents[1] / "RxCode/Resources/Pet/mlx_voice_worker.py"
)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class Model:
    def __init__(self, model_type, speakers=()):
        self.config = SimpleNamespace(model_type=model_type)
        self.speakers = speakers

    def get_supported_speakers(self):
        return self.speakers

    def generate(self, text, voice=None, speed=1, lang_code="auto", verbose=True):
        pass


class GenerationTests(unittest.TestCase):
    def test_incremental_audio_is_enabled_only_for_explicit_streaming_support(self):
        class StreamingModel(Model):
            def generate(self, text, stream=False, streaming_interval=2):
                pass

        kwargs = worker.generation_kwargs(StreamingModel("qwen3_tts"), "af_heart", 1, "a", 42)
        self.assertTrue(kwargs["stream"])
        self.assertEqual(kwargs["streaming_interval"], 0.5)
        self.assertNotIn("stream", worker.generation_kwargs(Model("kokoro"), "af_heart", 1, "a", 42))

    def test_switching_from_kokoro_to_qwen_base_omits_preset(self):
        kwargs = worker.generation_kwargs(Model("qwen3_tts"), "af_heart", 1, "a", 42)
        self.assertNotIn("voice", kwargs)
        self.assertEqual(kwargs["lang_code"], "english")

    def test_qwen_custom_voice_uses_a_supported_speaker(self):
        model = Model("qwen3_tts", ["Vivian", "Ryan"])
        self.assertEqual(worker.generation_kwargs(model, "af_heart", 1, "z", 42)["voice"], "Vivian")
        kwargs = worker.generation_kwargs(model, "ryan", 1, "z", 42)
        self.assertEqual(kwargs["voice"], "Ryan")
        self.assertEqual(kwargs["lang_code"], "chinese")

    def test_kokoro_preserves_its_voice_and_language(self):
        kwargs = worker.generation_kwargs(Model("kokoro"), "af_heart", 1.2, "a", 42)
        self.assertEqual(kwargs["voice"], "af_heart")
        self.assertEqual(kwargs["lang_code"], "a")
        self.assertEqual(kwargs["speed"], 1.2)


if __name__ == "__main__":
    unittest.main()
