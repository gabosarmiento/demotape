"""
DemoTape local TTS shim — a minimal server that speaks BOTH contracts DemoTape understands:

  POST /v1/audio/speech   OpenAI-compatible  {model, input, voice, response_format}  -> audio bytes
  POST /speak             DemoTape "Custom"  {text, voice, model}                    -> audio bytes
  GET  /v1/models         so DemoTape's "Test key" button gets a 200

Out of the box it uses `espeak-ng` (robotic, but zero downloads — proves the whole DemoTape
pipeline works offline). To use a real model, replace ONE function: `synth_wav()`. Point it at
Chatterbox, Qwen3-TTS, NVIDIA Canary, etc. The HTTP contract and DemoTape stay unchanged.

Run:
  docker build -t demotape-tts-shim . && docker run -p 8000:8000 demotape-tts-shim
"""
import subprocess
import tempfile
import os
from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel

app = FastAPI(title="DemoTape TTS shim")


def synth_wav(text: str, voice: str) -> bytes:
    """Return WAV audio bytes for `text`. THIS is the only piece to swap for a real model.

    Default: espeak-ng (installed in the image). Replace the body with your model call, e.g.
    Chatterbox / Qwen3-TTS / Canary, returning WAV (or any) bytes; the caller re-encodes to mp3.
    """
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav_path = f.name
    try:
        # espeak-ng maps a few DemoTape voice names to its own; unknown -> default voice.
        espeak_voice = {"": "en", "alloy": "en-us", "narrator": "en-us+m3"}.get(voice, voice or "en")
        subprocess.run(
            ["espeak-ng", "-v", espeak_voice, "-s", "165", "-w", wav_path, text],
            check=True, capture_output=True,
        )
        with open(wav_path, "rb") as fh:
            return fh.read()
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass


def to_mp3(wav_bytes: bytes) -> bytes:
    """Transcode WAV -> MP3 with ffmpeg (installed in the image), reading/writing via stdio."""
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "wav", "-i", "pipe:0",
         "-f", "mp3", "-b:a", "128k", "pipe:1"],
        input=wav_bytes, capture_output=True,
    )
    if proc.returncode != 0 or not proc.stdout:
        # Fall back to raw WAV if ffmpeg is unavailable; DemoTape decodes by content, not extension.
        return wav_bytes
    return proc.stdout


def render(text: str, voice: str) -> bytes:
    return to_mp3(synth_wav(text, voice))


# ---- OpenAI-compatible contract -------------------------------------------------------------
class SpeechRequest(BaseModel):
    model: str = "shim"
    input: str
    voice: str = ""
    response_format: str = "mp3"


@app.post("/v1/audio/speech")
def openai_speech(req: SpeechRequest):
    audio = render(req.input, req.voice)
    return Response(content=audio, media_type="audio/mpeg")


@app.get("/v1/models")
def models():
    # A minimal OpenAI-shaped models list so DemoTape's "Test key" probe returns 200.
    return JSONResponse({"object": "list", "data": [{"id": "shim", "object": "model"}]})


# ---- DemoTape "Custom" contract -------------------------------------------------------------
class SpeakRequest(BaseModel):
    text: str
    voice: str = ""
    model: str = "shim"


@app.post("/speak")
def speak(req: SpeakRequest):
    audio = render(req.text, req.voice)
    return Response(content=audio, media_type="audio/mpeg")


@app.get("/")
def health():
    return {"ok": True, "contracts": ["/v1/audio/speech", "/speak"]}
