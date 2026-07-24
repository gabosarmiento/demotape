# Local TTS for DemoTape (free, offline)

DemoTape's Voiceover works with **any** of three backends, chosen in **AI Settings → Voiceover →
Provider**:

| Provider | What it talks to | Key needed? |
|---|---|---|
| **ElevenLabs** | ElevenLabs hosted API (paid) | yes |
| **OpenAI-compatible** | `POST {baseURL}/audio/speech` — the standard the OpenAI SDK uses | usually no (local) |
| **Custom** | `POST {baseURL}` with `{text, voice, model}` → audio bytes | your choice |

"Run it locally" just means you launch a container that speaks one of those contracts and point
DemoTape's **Base URL** at it. No paid key, no network egress.

---

## Option A — Kokoro (recommended, zero-code)

[Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI) is a small OSS TTS server that already
speaks the OpenAI `/v1/audio/speech` contract. One command:

```bash
# CPU image — works on Apple Silicon and Intel (models are baked in)
docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu:latest
```

Then in DemoTape → **AI Settings → Voiceover**:

- **Provider:** `OpenAI-compatible`
- **Base URL:** `http://localhost:8880/v1`
- **Model:** `kokoro`
- **Voice:** `af_bella` (or any voice from `GET http://localhost:8880/v1/audio/voices`; combos like
  `af_bella+af_sky` work too)
- **API key:** leave blank

Click **Test key** — it should say "Server reachable." Generate a voiceover as usual. The
DemoTape driver picks this up headlessly too:

```bash
DEMOTAPE_TTS_PROVIDER=OpenAI-compatible \
DEMOTAPE_TTS_BASEURL=http://localhost:8880/v1 \
DEMOTAPE_TTS_MODEL=kokoro \
DEMOTAPE_TTS_VOICE=af_bella \
  node tools/demo-driver/driver.mjs tools/demo-driver/demo-kiff-aiready.json
```

Also works with **LocalAI** and **openedai-speech** — same contract, different port; just change the
Base URL.

---

## Option B — Wrap your own model (Chatterbox, Qwen3-TTS, Canary, …)

If you want a specific model that doesn't ship an OpenAI-compatible server, wrap it in the tiny
**custom shim** in `custom-shim/`. It exposes BOTH contracts (so you can use either Provider):

- `POST /v1/audio/speech`  — OpenAI-compatible (`{model, input, voice, response_format}`)
- `POST /speak`            — DemoTape "Custom" (`{text, voice, model}`)
- `GET  /v1/models`        — so the **Test key** button gets a 200

```bash
cd tools/tts-shim/custom-shim
docker build -t demotape-tts-shim .
docker run -p 8000:8000 demotape-tts-shim
```

Out of the box it synthesizes with `espeak-ng` (robotic, but proves the pipeline end-to-end with
zero downloads). To use a real model, replace the single `synth_wav()` function in `app.py` with a
call into Chatterbox / Qwen3-TTS / Canary — the HTTP contract and DemoTape stay unchanged.

DemoTape settings for the custom contract:

- **Provider:** `Custom`
- **Base URL:** `http://localhost:8000/speak`
- **Voice / Model:** whatever your model expects

…or point the **OpenAI-compatible** provider at `http://localhost:8000/v1`.

---

## The contracts, precisely

**OpenAI-compatible** (what DemoTape sends when Provider = OpenAI-compatible):

```
POST {baseURL}/audio/speech
Authorization: Bearer <key>        # omitted when no key is set
Content-Type: application/json
{ "model": "...", "input": "<text>", "voice": "...", "response_format": "mp3" }
→ 200, body = audio bytes (mp3)
```

**Custom** (Provider = Custom):

```
POST {baseURL}
Authorization: Bearer <key>        # omitted when no key is set
Content-Type: application/json
{ "text": "<text>", "voice": "...", "model": "..." }
→ 200, body = audio bytes (any AVFoundation-readable format; mp3/wav/m4a)
```

DemoTape writes the returned bytes to a temp file and transcodes to AAC/m4a before muxing, so any
common audio format works.

---

## Captions locally too (speech-to-text)

Captions use the **same pattern** — an OpenAI-compatible `/v1/audio/transcriptions` endpoint. Run a
local Whisper server and captions work free/offline with no key:

```bash
# faster-whisper-server / speaches (OpenAI-compatible STT)
docker run -p 8000:8000 fedirz/faster-whisper-server:latest-cpu
```

Then in DemoTape → **AI Settings → Captions**:

- **Provider:** `Local (OpenAI-compatible)`
- **Base URL:** `http://localhost:8000/v1`
- **Model:** a model the server exposes (e.g. `Systran/faster-whisper-base.en`)
- **API key:** leave blank (a `localhost` URL is treated as keyless)

Headless (driver / CLI) uses the existing env vars:

```bash
DEMOTAPE_STT_BASEURL=http://localhost:8000/v1 DEMOTAPE_STT_MODEL=Systran/faster-whisper-base.en \
  ./.build/release/DemoTape --captions "path/to/styled.mp4"
```

NVIDIA **Canary** / other models: wrap them behind the same `/v1/audio/transcriptions` contract
(or use a server like LocalAI that already does) and point the Base URL at it.
