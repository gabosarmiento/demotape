# Windows Port — Catch-Up Plan (macOS v5.2.0 parity)

The macOS app advanced to **v5.2.0** while the Windows port was being built. This document
inventories what the macOS app now does, maps each feature to a Windows-native approach, and gives
a prioritized roadmap — AI features first, per the maintainer's request.

The macOS changes live entirely in `Sources/DemoTape/**` (Swift) and do **not** conflict with the
Windows port under `windows/**`, so `main` can be merged into the port branch cleanly to keep the
reference implementation current.

## Current macOS menu (v5.2.0) — the target structure

```
Start Recording  (⇧⌘S)
Stop Recording   (⇧⌘S)
──────────────
Capture
  Record Full Screen                     ✅ Windows (radio)
  Select Recording Area…                 ✅ Windows (drag/resize/move overlay)
──────────────
Input ▸
  Record Microphone                      ✅
  Record Webcam                          ✅
  ──
  Smart Noise Suppression   (toggle)     ❌  AI/DSP audio
  Enhance Voice             (toggle)     ❌  AI/DSP audio
  ──
  Webcam Settings…                       ✅
Background ▸
  Choose Background… / No Background      ✅
Branding ▸
  Enable Branding / Branding Settings…   ❌  watermark/logo overlay
Teleprompter ▸
  Enable Teleprompter / Settings…        ❌  scrolling script overlay
──────────────
After Recording
  Auto-Cut & Speed Up Latest…            ❌  silence trim + speed-up
  AI Features ▸
    AI Settings…                         ❌  API keys (Credential Manager)
    Generate Captions for Latest…        ❌  transcription + burn-in
    Generate Voiceover for Latest…       ❌  ElevenLabs TTS
    Generate Avatar Presenter for Latest…❌  HeyGen cloud avatar
  Apply Template to Latest…              ❌  paced re-edit "looks"
  Web Publish Latest…                    ✅ (GIF export ❌)
──────────────
Recording Folder ▸ Change Output Directory…  ❌
System Preferences ▸ Open at Login / Show in Dock / Auto-Zoom  ◐ (auto-zoom done; others ❌)
About DemoTape                            ❌  About panel
Quit DemoTape                             ✅
Welcome / onboarding on first launches    ❌
Floating recorder bar + region frame      ✅ (our control bar + overlays)
Area presets (16:9, etc.)                 ❌
Render-complete notifications             ◐ (tray tooltip only)
```

Legend: ✅ done · ◐ partial · ❌ missing

## The "After Recording" pattern to replicate

On macOS each post-recording action opens a focused window: **source video on the left, result on
the right**, a few settings, a **Generate preview** button, playback, a **Reveal in Explorer** link,
and a **Change…** button to pick a different clip (`ActionPreviewController`). The Windows port should
adopt this same two-pane preview window as a reusable base (`ActionPreviewWindow`) so Captions,
Voiceover, Avatar, Auto-Cut, and Templates all feel consistent.

Output files land next to the recording (mirror macOS naming):
`*.styled.mp4`, `*.tight.mp4`, `*.captioned.mp4`, `*.voiceover.mp4`, `*.avatar.mp4`, `*-web/`.

## Feature → Windows mapping

### AI features (opt-in, bring-your-own-key; local by default)

| Feature | macOS impl | Windows-native approach |
|---|---|---|
| **AI Settings** (keys, test) | Keychain + `AISettingsController` | `Windows.Security.Credentials.PasswordVault` (Credential Manager) for keys; a WinUI settings window with masked fields + "Test key" buttons. Never write keys to disk. |
| **Captions** | on-device transcription → editable lines → burn-in (`Captions`, `CaptionBurner`) | On-device `Windows.Media.SpeechRecognition` (free, offline) for a first pass, or optional cloud (OpenAI/Azure) if a key is set. Burn captions with the existing Win2D renderer. Cache the transcript in the sidecar so re-opening is free. |
| **Voiceover** | ElevenLabs TTS over the script (`Voiceover`, ElevenLabs provider) | Same ElevenLabs REST API via `HttpClient`; list voices, one-click preview, mux narration with `MediaComposition`. Provider-agnostic interface so we can add Azure/OpenAI TTS later. |
| **Avatar Presenter** | HeyGen cloud, photo/library avatar, chroma-key/circle composite, cost confirm (`HeyGenAvatarProvider`, `AvatarCompositor`) | Same HeyGen REST API; upload photo, poll job, chroma-key + circular mask via Win2D into the webcam bubble. Show a **cost estimate + confirm** dialog before spending credits. |
| **Smart Noise Suppression** | on-device denoise (`NoiseReducer`) | Media Foundation audio processing or a lightweight spectral gate. Harder to match quality without a DSP lib; start with a tunable noise gate, evaluate RNNoise later. |
| **Enhance Voice** | studio EQ + compression (`VoiceEnhancer`) | Media Foundation audio effects / manual biquad EQ + compressor on the mic track before mux. |

### Studio / editing

| Feature | Windows-native approach |
|---|---|
| **Auto-Cut & Speed Up** (`Tightener`) | Analyze mic RMS to find silent gaps; drop/trim them and optionally speed the clip via `MediaComposition` time-remap. Fully local. |
| **Apply Template** (`TemplateComposer`, `VideoTemplate`) | A set of paced "looks" (Clean, Keynote, Commercial): intro/outro cards, transition timing, zoom rhythm — implemented as render presets in the Win2D pipeline. |
| **Two-pane action windows** (`ActionPreviewController`) | Reusable `ActionPreviewWindow` (MediaPlayerElement source/result, Generate preview, Reveal, Change…). |

### Recording chrome / UX

| Feature | Windows-native approach |
|---|---|
| **Branding / watermark** | Logo overlay (position/opacity/scale) baked by the renderer; settings window; `Enable Branding` toggle. |
| **Teleprompter** | A always-on-top, click-through scrolling-script overlay (reuse the layered-window infra); speed/size/opacity in a settings window. Excluded from capture via `WDA_EXCLUDEFROMCAPTURE`. |
| **Area presets** | 16:9 / 4:3 / 1080p etc. that constrain the region selector aspect + export size. |
| **GIF export** | Add an animated-GIF tier to Web Publish (frame sampling + palette quantization). |
| **Change Output Directory** | Folder picker; persist in settings (we already resolve output dir). |
| **Open at Login** | Startup registration (registry `Run` key or `StartupTask`). |
| **About + Welcome/onboarding** | Simple WinUI windows; show welcome on first few launches. |
| **Render notifications** | Toast via `AppNotificationManager` (community toolkit) instead of just the tray tooltip. |

## Proposed roadmap (each phase = its own PR)

**Phase A — Foundation for post-processing (unblocks all AI)**
1. `ActionPreviewWindow` (two-pane source/result base).
2. `AISettingsWindow` + Credential Manager key store + provider interfaces.
3. "After Recording" + "AI Features" menu sections wired to stub actions.

**Phase B — AI captions & voiceover (highest value, lowest risk)**
4. Captions: on-device transcription → editable lines → burn-in; cache transcript in sidecar.
5. Voiceover: ElevenLabs provider, voice preview, mux narration.

**Phase C — Audio polish**
6. Enhance Voice (EQ + compressor).
7. Smart Noise Suppression (noise gate first).
8. Auto-Cut & Speed Up.

**Phase D — Avatar presenter**
9. HeyGen provider + cost-confirm + Win2D chroma/circle composite.

**Phase E — Editing & chrome**
10. Apply Template looks.
11. Branding/watermark.
12. Teleprompter overlay.
13. Area presets, GIF export, Change Output Directory, Open at Login, About/Welcome, toast notifications.

## Recommended first step

Merge `origin/main` into `feat/windows-port` (no conflicts — different directories) so the port
sits on current macOS reference code and PR #5 stays current. Then start **Phase A**, since every AI
feature depends on the action-window + AI-settings foundation.
