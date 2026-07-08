# AI Captions

DemoTape can transcribe a recording's audio into `.srt` and `.vtt` subtitle files using an
**OpenAI-compatible speech-to-text API**. It's **opt-in** and **bring-your-own-key**: nothing
leaves your Mac unless you configure a key and run it yourself, and the audio is uploaded only
to the endpoint *you* choose.

## Quick start

1. **Install the latest build** (menu items only appear after you reinstall):
   ```bash
   ./build-app.sh release
   open /Applications/DemoTape.app
   ```
2. **Turn on AI features:** menu bar icon → **AI Features → AI Settings…** Tick
   **Enable AI features**, pick a **Provider** (OpenAI or Groq auto-fills the URL and model),
   paste your **API key**, then **Save**. The key is stored in the macOS **Keychain** (not a
   file), so you enter it once.
3. **Record something** and stop — captions run on your most recent recording in
   `~/Movies/DemoTape/` (make sure **Record Microphone** was on).
4. Menu bar icon → **AI Features → Generate Captions for Latest…**
5. A simple editor opens with one row per subtitle line (rows grow to fit the text, so you
   can read/edit the whole line). **Fix any wording** — timings stay as transcribed. Then:
   - **Save** — writes `…styled.srt` and `…styled.vtt` next to the video (for players,
     YouTube, or the Web Publish `<video>` embed).
   - **Add to Video** — burns the captions into a new `…captioned.mp4` (bottom-center,
     rounded translucent box). The original is untouched.

**It only transcribes once.** The transcript is cached next to the recording
(`…transcript.json`, and it also reuses an existing `.srt`), so re-opening the editor for the
same recording is instant and does **not** call the API again — no repeat charges.

## Enabling AI features

AI is **off by default** — the app makes no network requests until you turn it on. The
**AI Features → AI Settings…** panel is the single place to:

- **Enable AI features** (master switch). While off, the captions action is disabled and
  points you here.
- Choose a **Provider** preset — **OpenAI** and **Groq** auto-fill the Base URL and a default
  model; pick **Custom** for a local Whisper server or another compatible endpoint.
- Enter your **API key** (saved to the Keychain), and optionally a **language** hint.

## Where your key is stored

- The API key is stored in the **login Keychain** under service `dev.demotape.app`,
  account `stt-api-key`. It is never written to UserDefaults or to disk in the clear.
- Base URL, model, and optional language hint are stored in normal app preferences
  (they're not secret).
- To remove the key later: Keychain Access → search "demotape" → delete the item.

## Supported providers

Captions work with any service that exposes OpenAI's multipart
`POST {baseURL}/audio/transcriptions` endpoint running a Whisper-style model.

| Provider | Base URL | Model | Notes |
|---|---|---|---|
| **OpenAI** (default) | `https://api.openai.com/v1` | `whisper-1` | Max 25 MB audio per request. |
| **Groq** | `https://api.groq.com/openai/v1` | `whisper-large-v3` | Fast and inexpensive. Also `whisper-large-v3-turbo`. |
| **Local Whisper** (whisper.cpp server, LocalAI, faster-whisper) | e.g. `http://localhost:8080/v1` | the server's model id | Fully offline. |
| **OVHcloud AI Endpoints** | provider endpoint | `whisper-large-v3` | OpenAI-compatible transcription. |

### Not supported for captions

- **Claude / Anthropic** — has no speech-to-text API (text + vision only). There's nothing to
  transcribe with. (Claude could later help *clean up* a transcript, but not create one.)
- **Novita** — its audio API is text-to-**speech** (TTS), not speech-to-text. (Useful later
  for the planned voiceover feature, not for captions.)
- **OpenRouter** — its STT endpoint uses a base64-JSON request shape, not the multipart form
  DemoTape sends, so it won't work as-is.

## Cost and limits

- OpenAI `whisper-1` bills per minute of audio; a 2-minute demo costs a fraction of a cent.
- OpenAI's transcription request limit is **25 MB** of audio. DemoTape extracts a compact
  `.m4a` before uploading, so a couple of minutes of narration stays well under that.
- For long recordings, use a local Whisper server (no size/network limit) or Groq.

## Testing from the command line (no GUI, no Keychain)

The binary has a headless hook that reads the key from the environment — handy for scripts
or CI:

```bash
DEMOTAPE_STT_KEY=sk-... ./.build/release/DemoTape --captions ~/Movies/DemoTape/your.styled.mp4

# Point at Groq instead of OpenAI:
DEMOTAPE_STT_KEY=gsk_... \
DEMOTAPE_STT_BASEURL=https://api.groq.com/openai/v1 \
DEMOTAPE_STT_MODEL=whisper-large-v3 \
  ./.build/release/DemoTape --captions ~/Movies/DemoTape/your.styled.mp4

# Optional language hint (ISO-639-1), otherwise auto-detected:
DEMOTAPE_STT_LANG=en ...
```

It writes `.srt` and `.vtt` next to the input and prints their paths.

## Troubleshooting

- **"No API key configured"** — you cancelled the dialog or left the key blank.
- **"HTTP 401"** — wrong or expired key, or wrong Base URL for that key (an OpenAI key won't
  work against the Groq URL, and vice-versa).
- **"HTTP 404"** — the Base URL is wrong. It must end at the API version (e.g. `…/v1`); the
  app appends `/audio/transcriptions`.
- **"The recording has no audio track"** — you recorded with the microphone off. Enable
  **Record Microphone** before recording.
- **Menu item missing** — you're running an older build. Re-run `./build-app.sh release` and
  relaunch from `/Applications`.
