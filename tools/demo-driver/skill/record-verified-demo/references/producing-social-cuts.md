# Producing social cuts (post-production, agent-led)

This is the phase **after** you have one honest, verified video: turning it into something that
actually holds attention on TikTok / Reels / Shorts / LinkedIn. It is a *skill*, not a wizard — the
app gives you the primitives (they run locally and free), and you make the editorial calls.

Two rules frame everything here:

1. **Ship the honest cut first, then offer enhancements.** Record → rehearse → verify → hand back a
   working video *before* you touch pacing, reframing, or captions. Enhancements are proposed on top
   of a thing that already works, never as a precondition for it. A demo that's real but plain beats
   a slick one that lies.
2. **Never burn credits speculatively.** Know which steps cost money and which don't (below), reuse
   caches, and only spend on a paid step when the user has said yes to *that* output. Most of
   post-production is free.

## Interaction model: intent in, video out (no menus)

This is an **AI-guided capability, not a UI the user drives**. The user says what they want in plain
language — *"make it a portrait video for TikTok," "give me a 1:1 for LinkedIn," "a vertical Reel,"
"something for Shorts"* — and you (the agent) detect the intent, pick the target, and produce it,
applying the sensible defaults below. Don't present a checklist or ask the user to choose each step;
the whole point is that they'd struggle to do this by hand and shouldn't have to.

Map the stated intent to a target and just do it:

| The user says… | Target | Default treatment |
|---|---|---|
| TikTok · Reel · Shorts · "vertical" · "portrait" | 9:16 | reframe (follow the action) + tighten + burned captions |
| "square" · LinkedIn/IG feed post | 1:1 | reframe + tighten + burned captions |
| "portrait post" · 4:5 | 4:5 | reframe + tighten + burned captions |
| YouTube · "landscape" | 16:9 | tighten + captions (no reframe needed) |

The **free, local** steps (reframe, tighten, burn captions) are applied **by default** — that's the
"smart enough not to make me do it" part. You only pause to ask the user about two things: **spending
credits** (a new voice, a first transcription, a vision pass) and a genuine **editorial fork** you
can't infer (e.g. which 20 seconds are the story, if it isn't obvious). Everything else, decide and
do — then hand back the result and iterate on feedback.

## What costs money, and what doesn't

| Free / local (run freely) | Paid (spend deliberately) |
|---|---|
| `--tighten` (pace, cut silence, speed) | TTS voice synthesis (`--voiceover*`, `narrate`) |
| `--reframe` (portrait/where-to-look) | STT transcription (`--captions`, first time) |
| `--burn` (subtitles, from a cached transcript/SRT) | Vision gate (`--verify`) |
| `--render` / `--recipe` (look, zoom, size) | |
| `--frame`, `--publish`, `--transcode` | |

So: **cut, reframe, restyle, and re-burn captions as often as you like.** Transcribe once and reuse
the cached transcript. Only re-synthesize a voice or re-run the vision gate when the content actually
changed and the user wants that specific artifact. Translations are cached by (voice, text) — a
second pass only pays for the lines you changed.

## The default pipeline (the agent applies it, in order)

After the verified first cut, run these for a social request — they're free and reversible, so apply
them by default rather than asking. Each is one command.

1. **Tighten the pace.** Short-form lives or dies on momentum: cut every pause and dead frame, and
   consider a gentle speed-up. `--tighten <video> [speed] [removeSilence]` (e.g. `1.2 1` = 1.2× and
   drop silences). Aim for a visible change every ~2–3 seconds; a static shot longer than that reads
   as sluggish.
2. **Reframe for where it's going.** Vertical is not a resized desktop crop — cropping 16:9 to 9:16
   drops ~two-thirds of the width, so the *right region* has to be kept and moved as the action
   moves. This is what `--reframe` is for (see `reframe-spec` / the design doc): it uses the
   recording's own click/scroll/zoom timeline to keep the focus in frame, instead of a blind
   center-crop. Design for the **smallest screen** — a phone — and keep the product big enough to read.
3. **Burn captions — always.** Most people watch muted, so captions aren't optional for social. Use a
   silent-legible style (`one-word` / `word-pair` for the punchy social look; `clean`/`bold` for full
   lines). `--captions` once to transcribe, then `--burn <video> <style> [--srt <edited-or-translated>]`.
4. **Restyle if needed.** Zoom emphasis, export size, branding — `--render … --recipe` (a 1-key patch,
   re-derived from the raw take; no re-record).

## The craft (what "good" looks like right now)

Grounded in how short-form product video is actually made:

- **Hook in the first ~2 seconds.** Open on the payoff or the single promise, product visible
  immediately — not a slow intro. The hook is a *record-time* decision: script the scene order so the
  most compelling moment is first. Re-ordering after the fact is a re-record, not a re-render, so get
  it right in the script.
- **One idea up front.** State the single thing this video is about in the first beat; don't tease.
- **Value loop, ~3–25s.** Deliver on the hook immediately, one short sentence per beat, a visible
  change every 2–3s (a click, a scroll to the next section, a zoom onto the result).
- **Deliver value in 20–30s.** You can run to 60–90s for a full explainer, but the core payoff should
  land early. Assume most viewers leave before the end — front-load.
- **Captions on screen, chunked for muted autoplay.** Short caption blocks that track the voice.
- **Keep the product big and legible.** On a phone, tiny UI is dead. Use zoom to make the thing being
  talked about fill the frame (DemoTape already zooms on real clicks — lean on it).
- **Consider platform recuts, not re-records.** The same footage becomes a 9:16 TikTok cut and a 1:1
  LinkedIn post via `--reframe` + a caption restyle. Never re-record for aspect or platform.

## Attention is data here, not a guess

DemoTape recorded the clicks, typing, scrolls, cursor path, and the auto-zoom focus timeline
(`events.json` beside the raw take). Every pacing and reframing decision can read that ground truth
instead of guessing: cut the gaps where nothing happened, keep the click target in the vertical
frame, hold the frame while typing, pan on a scroll or a new click. When you reframe or tighten,
you're editing *from what actually happened*, which is why it can be automatic and still correct.

## Anti-slop checklist (social cut)

- [ ] A verified first cut existed before any enhancement pass.
- [ ] Hook in the first ~2s; the single promise is clear immediately.
- [ ] Core value delivered within ~20–30s; front-loaded, not saved for the end.
- [ ] Fast pace: silences cut, a visible change every 2–3s (`--tighten` used).
- [ ] Captions burned in and legible with the sound off.
- [ ] Portrait keeps the *right region* in frame (reframed from the focus/events timeline), not a
      blind center-crop that drops the action.
- [ ] Product stays big enough to read on a phone.
- [ ] Platform variants are reframes/restyles of the same footage — no re-record for aspect.
- [ ] No paid step (voice, transcription, vision) was spent speculatively; caches reused.
