#!/usr/bin/env python3
"""
Persistent MLX Audio TTS worker for RxCode Pet Voice Mode.
Keeps the selected MLX TTS model warm in unified memory and streams
24 kHz 16-bit mono PCM chunks encoded as base64 JSON lines over stdout.
"""

import base64
import inspect
import json
import random
import sys
import threading
import traceback
import numpy as np


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def resample_to_24k(audio: np.ndarray, src_rate: int) -> np.ndarray:
    if audio.ndim > 1:
        audio = np.mean(audio, axis=-1)
    audio = np.asarray(audio, dtype=np.float32).reshape(-1)
    if audio.size == 0 or src_rate <= 0 or src_rate == 24000:
        return audio
    duration = audio.size / float(src_rate)
    dst_len = max(1, int(round(duration * 24000.0)))
    src_x = np.linspace(0.0, 1.0, num=audio.size, endpoint=False)
    dst_x = np.linspace(0.0, 1.0, num=dst_len, endpoint=False)
    return np.interp(dst_x, src_x, audio).astype(np.float32)


def float_to_pcm16_b64(audio: np.ndarray) -> str:
    clipped = np.clip(audio, -1.0, 1.0)
    pcm16 = (clipped * 32767.0).astype("<i2")
    return base64.b64encode(pcm16.tobytes()).decode("ascii")


# Locale language prefix -> Qwen3-TTS language name.
QWEN_LANGUAGES = {
    "zh": "chinese", "en": "english", "ja": "japanese", "ko": "korean",
    "de": "german", "fr": "french", "ru": "russian", "pt": "portuguese",
    "es": "spanish", "it": "italian",
}

# Short neutral sentences used to render the seeded reference voice for Qwen Base.
REFERENCE_TEXTS = {
    "chinese": "你好，我是你的编程小伙伴。今天我们一起把代码写得更好吧。",
    "english": "Hi there, I am your coding companion. Let's make today's work a little easier together.",
    "japanese": "こんにちは、私はあなたのコーディング仲間です。今日も一緒に頑張りましょう。",
    "korean": "안녕하세요, 저는 당신의 코딩 친구예요. 오늘도 함께 힘내요.",
    "german": "Hallo, ich bin dein Programmierbegleiter. Lass uns heute gemeinsam gute Arbeit machen.",
    "french": "Bonjour, je suis ton compagnon de code. Faisons du bon travail ensemble aujourd'hui.",
    "russian": "Привет, я твой помощник по программированию. Давай сегодня поработаем вместе.",
    "portuguese": "Olá, eu sou seu companheiro de programação. Vamos fazer um bom trabalho juntos hoje.",
    "spanish": "Hola, soy tu compañero de programación. Hagamos un buen trabajo juntos hoy.",
    "italian": "Ciao, sono il tuo compagno di programmazione. Facciamo un buon lavoro insieme oggi.",
}


def qwen_language(model, locale: str, lang_code: str) -> str:
    """Resolve the Qwen language from the conversation locale, not the Kokoro preset."""
    prefix = locale.replace("_", "-").split("-")[0].lower() if locale else ""
    language = QWEN_LANGUAGES.get(prefix)
    if language is None:
        language = {"a": "english", "b": "english", "z": "chinese", "j": "japanese"}.get(lang_code, "auto")
    supported = [s.lower() for s in (getattr(model, "supported_languages", None) or [])]
    if supported and language not in supported:
        return "auto"
    return language


def is_qwen_base(model) -> bool:
    config = getattr(model, "config", None)
    if getattr(config, "model_type", "") != "qwen3_tts":
        return False
    if getattr(config, "tts_model_type", "base") != "base":
        return False
    tokenizer = getattr(model, "speech_tokenizer", None)
    return bool(getattr(tokenizer, "has_encoder", False))


def generation_kwargs(model, voice: str, speed: float, lang_code: str, seed: int, locale: str = "") -> dict:
    params = inspect.signature(model.generate).parameters
    accepts_varkw = any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params.values())
    config = getattr(model, "config", None)
    model_type = getattr(config, "model_type", "")
    if model_type == "qwen3_tts":
        # Kokoro presets persist when switching models. Qwen Base has no preset
        # speakers; omitting voice selects its unconditioned generation path.
        speakers = model.get_supported_speakers()
        voice = next((s for s in speakers if s.lower() == voice.lower()), speakers[0] if speakers else "")
        lang_code = qwen_language(model, locale, lang_code)

    kwargs = {}
    for name, value in (("voice", voice), ("speed", speed), ("lang_code", lang_code)):
        if (name in params or accepts_varkw) and value != "":
            kwargs[name] = value
    if "seed" in params:
        kwargs["seed"] = seed
    if "verbose" in params:
        kwargs["verbose"] = False
    # Chunking a completed waveform does not reduce time to first audio. Ask
    # engines with explicit streaming support to decode while generating.
    if "stream" in params:
        kwargs["stream"] = True
        if "streaming_interval" in params:
            kwargs["streaming_interval"] = 0.5
    return kwargs


def main() -> int:
    if len(sys.argv) < 2:
        emit({"event": "error", "message": "Missing model directory path"})
        return 1

    model_path = sys.argv[1]
    try:
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model
        model = load_model(model_path)
    except Exception as exc:
        emit({"event": "error", "message": f"Failed to load MLX voice model: {exc}"})
        return 1

    default_sr = int(getattr(model, "sample_rate", 24000) or 24000)
    emit({"event": "ready", "sample_rate": 24000, "model_sample_rate": default_sr})

    cancel_generation = [0]
    lock = threading.Lock()
    synthesis_lock = threading.Lock()
    # (seed, language) -> (reference waveform, reference transcript)
    reference_voices = {}
    qwen_base = is_qwen_base(model)

    def seed_all(seed: int) -> None:
        mx.random.seed(seed)
        np.random.seed(seed)
        random.seed(seed)

    def reference_voice(seed: int, language: str):
        """Render one seeded clip and reuse it as the cloning reference.

        Qwen Base samples a new speaker for every unconditioned call, so the seed
        alone only repeats audio for identical text. Cloning one seeded clip keeps
        every sentence, reply, and notification in the same voice.
        """
        key = (seed, language)
        cached = reference_voices.get(key)
        if cached is not None:
            return cached
        ref_text = REFERENCE_TEXTS.get(language, REFERENCE_TEXTS["english"])
        seed_all(seed)
        kwargs = {"lang_code": language, "verbose": False}
        pieces = [np.array(getattr(r, "audio", r), dtype=np.float32).reshape(-1)
                  for r in model.generate(ref_text, **kwargs)]
        pieces = [p for p in pieces if p.size]
        if not pieces:
            return None
        cached = (mx.array(np.concatenate(pieces)), ref_text)
        reference_voices[key] = cached
        return cached

    def run_synthesis(req_id: str, text: str, voice: str, speed: float, lang_code: str, seed: int, locale: str, gen_token: int) -> None:
        with synthesis_lock:
            try:
                with lock:
                    if cancel_generation[0] != gen_token:
                        emit({"event": "cancelled", "id": req_id})
                        return
                kwargs = generation_kwargs(model, voice, speed, lang_code, seed, locale)
                if qwen_base:
                    reference = reference_voice(seed, kwargs.get("lang_code", "auto"))
                    if reference is not None:
                        kwargs.pop("voice", None)
                        kwargs["ref_audio"], kwargs["ref_text"] = reference
                    with lock:
                        if cancel_generation[0] != gen_token:
                            emit({"event": "cancelled", "id": req_id})
                            return
                seed_all(seed)

                for result in model.generate(text, **kwargs):
                    with lock:
                        if cancel_generation[0] != gen_token:
                            emit({"event": "cancelled", "id": req_id})
                            return

                    audio = getattr(result, "audio", result)
                    sr = int(getattr(result, "sample_rate", default_sr) or default_sr)
                    np_audio = np.array(audio, dtype=np.float32)
                    resampled = resample_to_24k(np_audio, sr)
                    if resampled.size == 0:
                        continue

                    # Stream in ~100 ms frames (2400 samples @ 24kHz) for smooth UI meters and instant barge-in
                    step = 2400
                    for offset in range(0, resampled.size, step):
                        with lock:
                            if cancel_generation[0] != gen_token:
                                emit({"event": "cancelled", "id": req_id})
                                return
                        chunk = resampled[offset : offset + step]
                        emit({"event": "audio", "id": req_id, "pcm": float_to_pcm16_b64(chunk)})

                emit({"event": "done", "id": req_id})
            except Exception as exc:
                emit({
                    "event": "error",
                    "id": req_id,
                    "message": f"{exc}",
                    "trace": traceback.format_exc(limit=3),
                })

    worker_thread = None

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except Exception:
            continue

        op = cmd.get("op")
        if op == "cancel":
            with lock:
                cancel_generation[0] += 1
            emit({"event": "cancelled", "id": cmd.get("id", "")})
        elif op == "quit":
            with lock:
                cancel_generation[0] += 1
            break
        elif op == "speak":
            with lock:
                cancel_generation[0] += 1
                token = cancel_generation[0]
            if worker_thread is not None and worker_thread.is_alive():
                worker_thread.join(timeout=0.15)
            req_id = str(cmd.get("id", ""))
            text = str(cmd.get("text", "")).strip()
            if not text:
                emit({"event": "done", "id": req_id})
                continue
            voice = str(cmd.get("voice", "") or "")
            speed = float(cmd.get("speed", 1.0) or 1.0)
            lang_code = str(cmd.get("lang_code", "") or "")
            seed = max(0, min(int(cmd.get("seed", 42)), 2147483647))
            locale = str(cmd.get("locale", "") or "")
            worker_thread = threading.Thread(
                target=run_synthesis,
                args=(req_id, text, voice, speed, lang_code, seed, locale, token),
                daemon=True,
            )
            worker_thread.start()

    return 0


if __name__ == "__main__":
    sys.exit(main())
