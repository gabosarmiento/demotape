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

<video src="https://github.com/gabosarmiento/demotape/releases/download/v6.6.0/demotape-demo.mp4" controls width="100%"></video>

If the player doesn't load,
[watch the demo here](https://github.com/gabosarmiento/demotape/releases/download/v6.6.0/demotape-demo.mp4).

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

## Or record it yourself

Click the menu-bar icon (**⇧⌘S**), pick **Full Screen** or an area, and a floating bar appears:
Start/Stop, a timer, mic and webcam toggles, and a **•••** for what you set before a take —
background, branding, teleprompter, auto-zoom. Press Stop and DemoTape auto-edits a polished video
(smooth zoom, clean cursor) into `~/Movies/DemoTape/`.

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
