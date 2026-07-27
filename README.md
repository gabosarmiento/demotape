# DemoTape

**Make product demos agentically, on your Mac.** Describe a feature and let your coding agent do the
whole thing — read the codebase, script the scenes, drive the app, record, narrate, and verify each
scene before handing back the video. Or record it yourself and let DemoTape polish it. Local-first,
no account, free and open source.

Runs on **macOS 12.3+** (Intel or Apple Silicon) — including older Macs like Monterey 12.7.6.

> Free forever — no account, no license, no upsell. If it saved you time,
> [**★ star the repo**](https://github.com/gabosarmiento/demotape).

## See it

This demo was made by a coding agent — scripted, recorded, narrated and verified — then sped up and
captioned, all from prompts:

[![Watch the demo](media/demo-poster.jpg)](https://github.com/gabosarmiento/demotape/releases/download/v7.0.0/demotape-demo.mp4)

▶ [**Watch the 2-minute demo**](https://github.com/gabosarmiento/demotape/releases/download/v7.0.0/demotape-demo.mp4)

<!--
  To play INLINE (like DeepFilterNet's README), GitHub needs an "attachment" URL, which is only
  minted by uploading through the web UI — a release-download or raw URL will NOT render a player.
  One-time step: edit this README on github.com, drag demotape-demo.mp4 into the editor, and GitHub
  inserts a line like  https://github.com/gabosarmiento/demotape/assets/<id>/<uuid>  — replace the
  poster block above with that bare URL on its own line and the player embeds directly.
-->


---

## What "agentically" means here

A real run, start to finish, driven entirely by prompts:

1. **Understand the app.** The agent read a codebase (KIFF, an AI-governance platform), installed the
   skill, and worked out what was worth showing and how to reach it.
2. **Script and record.** It stood up the local stack, wrote the scenes, drove the browser, and
   recorded — narration synced to each action.
3. **Verify.** Every scene was checked against what was actually on screen; a take that showed the
   wrong thing fails loudly instead of shipping.
4. **Polish, by prompt.** Sped up to 1.25×, captions burned in, then the whole thing re-voiced in
   **Spanish** and **French** — same footage, new narration and subtitles, no re-recording.

All of that from plain instructions. That's the difference from "AI polish on a screen recording":
a different actor does the work, and it proves the result before you see it.

**Get started:**

```bash
tools/demo-driver/skill/install.sh              # Claude Code (~/.claude/skills)
tools/demo-driver/skill/install.sh --kiro       # Kiro (this workspace)
tools/demo-driver/skill/install.sh --dir <path> # any other skills directory
```

Then, in a checkout of your app, ask your agent:

> Record a verified demo of &lt;feature&gt; in this app.

You get a `…voiceover.mp4` and a `demo-report.json` with a per-scene verdict. The full playbook is in
[`SKILL.md`](tools/demo-driver/skill/record-verified-demo/SKILL.md). In the app it's the first menu
item: **Let Your Coding Agent Record a Demo…**

---

## Record yourself to camera (webcam only)

Not every video is a screen demo. **Webcam Only** is a first-class capture mode — pick it from the
menu-bar icon (under **Select Recording Area**) or the floating bar's **•••** — and DemoTape records
just your camera at 1080p, a clean talking-head. A near-full-screen live preview makes it obvious the
camera is the whole video, and an optional teleprompter scrolls on screen for you but **never appears
in the recording** (it captures the camera, not the screen), sitting in whichever edge strip you pick.
Mirror the image with **Mirror camera**, and clean the mic with **Enhance audio** and **Noise
suppression**. The result is a normal recording, so Captions, Voiceover and Web Publish all work on it.

This is where the agent shines again — it can write the script and run the teleprompter for you:

> Help me make a 1-minute YC application video. Write it to sound natural when spoken (per
> ycombinator.com/video), load it into the teleprompter, and tell me when to start.

> Help me make a 2-minute interview intro about me — ask me what you need, draft the teleprompter,
> then count me in and record webcam-only.

The agent loads the teleprompter, says "ready when you are", counts 3-2-1, and records you to camera.
Copy the prompt for your agent from the composer, or drive it directly (`demotape://record/webcam`).

## Or record your screen

Click the menu-bar icon (**⇧⌘S**), pick **Full Screen** or an area, and a floating bar appears:
Start/Stop, a timer, mic and webcam toggles, and a **•••** for what you set before a take —
background, branding, teleprompter, auto-zoom. Pick an area and you can **lock** it in place to click
and scroll the app beneath while framing your shot, then unlock to adjust. Press Stop and DemoTape
auto-edits a polished video (smooth zoom, clean cursor) into `~/Movies/DemoTape/`.

Then, under **After Recording**, each step opens a source→result window with a **Generate preview**:

- **Auto-Cut / Auto-Edit** — trim silences and tighten pace, or re-edit with a paced look. Local.
- **Captions** — transcribe, edit the lines, burn them in. Includes word-by-word social styles.
- **Voiceover** — turn a script into narration; add another **language** on the same timings.
- **Avatar** — a photorealistic presenter that lip-syncs to your voiceover (cloud, shows cost first).
- **Web Publish** — lightweight MP4 tiers, a poster, an embed snippet, and a GIF.

Captions, Voiceover, and Avatar can also hand the job to your coding agent with **Copy prompt for
your agent**.

---

## Get DemoTape

**Download.** Grab `DemoTape-<version>.dmg` from
[Releases](https://github.com/gabosarmiento/demotape/releases/latest) and drag it into
**Applications**. It's Developer-ID signed and notarized, so it opens normally. Run it from
**/Applications** so macOS remembers Screen Recording permission.

**Build from source.**

```bash
./create-identity.sh    # one-time signing identity (keeps permissions across rebuilds)
./build-app.sh release  # build, sign, install to /Applications
```

No Xcode project, no third-party dependencies — Apple frameworks and `swift build`. See
[`AGENTS.md`](AGENTS.md) for build/verify steps.

**First launch** asks for **Screen Recording**: click Allow, tick DemoTape in System Settings, then
Quit & Reopen (macOS applies it on relaunch). Mic, Camera, and Accessibility are asked for only when
a feature needs them.

---

## Private by default

DemoTape makes **no network calls** unless you turn on an AI step. Those are opt-in and use **your
own API keys** (stored in the macOS Keychain), or a local OpenAI-compatible server for free, offline
captions and voiceover — see [`tools/tts-shim`](tools/tts-shim). Only what a step needs is sent:
captions send the audio, voiceover the script. **Your screen recording is never uploaded.**

---

## Windows

A **work-in-progress** Windows 11 port lives in [`windows/`](windows/) (C# · .NET 8 · WinUI 3). Today
it does traditional screen recording and the auto-styled render; the AI-director, captions, voiceover
and avatar features are macOS-only for now. See [`windows/README.md`](windows/README.md).

---

## License

MIT — see [LICENSE](LICENSE). A dependency-free implementation of its own; built by studying, not
copying, other open-source recorders. Bug reports and pull requests welcome.
