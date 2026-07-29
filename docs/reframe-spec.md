# `--reframe`: smart vertical/social reframing — design spec

Status: **proposal** (for review before building). Owner-facing engineering doc.

## Problem

Turning a 16:9 screen demo into a 9:16 (or 1:1 / 4:5) social cut loses ~two-thirds of the width. A
blind center-crop — what `PlatformCrop` does today — routinely drops the exact thing being
demonstrated (a button in the corner, a side panel, a form on the right). Humans fix this by hand,
moving the crop scene to scene and zooming onto the action. That's the slow, skilled work we want to
automate.

## The key asset: we already know where to look

DemoTape records the interaction as ground truth in `events.json` beside the raw `.mov`:

- `clicks[]` (t, x, y) — where the user acted,
- `cursor[]` (t, x, y, kind) — the cursor path,
- `scrolls[]`, `keys[]` (typing, with an optional caret position),
- `display` geometry (point/pixel size, scale).

And `FocusTimeline` already turns clicks/keys into an **auto-zoom camera** (target rect over time,
spring-eased, with a hold while typing). Every other tool on the market *guesses* salience with
vision; here it's data. **`--reframe` reads the same focus model and maps it into the target aspect.**
That's the whole idea, and it's why this can be automatic and still correct.

## Output

A new file beside the original (non-destructive), rendered to the target size (e.g. 1080×1920), where
each moment frames the salient region — never a static center-crop. Captions are burned in by default
(social is watched muted). The raw `.mov` + `events.json` stay the source of truth, so a reframe can
be re-derived at any aspect/layout later, exactly like `--render`.

## Layout vocabulary

The reframer picks (or is told) a layout per segment:

1. **`portrait-follow` (v1, the flagship).** Crop + zoom to the salient region and fill the vertical
   frame; the crop center follows the focus timeline, spring-eased, holding still while typing and
   panning on clicks/scrolls. This is the "keep the button in frame" behavior.
2. **`fit-blur`.** For wide-context moments with no single focus (an overview, a first reveal): fit
   the whole frame, fill the margins with a blurred cover of itself (reuse the blurred-fill idea).
   Used as a fallback and for establishing shots.
3. **`band` (content + caption band).** Reserve a bottom band for large burned captions; the content
   area above frames the focus. The social-native look.
4. **`split` / `stacked` (v2).** Two stacked regions — e.g. the full landscape context on top and a
   zoomed detail below, or a webcam bubble + the zoomed action. For demos where context *and* detail
   both matter.

Transitions between segments are eased (reuse the spring camera), never hard jumps.

## How segments are chosen

- Segment the timeline at **focus changes**: a new click cluster, a scroll, a scene boundary. Between
  boundaries, hold a stable frame (don't chase every cursor pixel — mirror the existing
  zoom-hold-while-typing logic so text doesn't jitter the frame).
- Each segment gets: a focus rect (from `FocusTimeline`), a layout, and a target crop rect in the
  output aspect. Pure geometry, unit-testable.
- **Safe zones:** keep the focus rect clear of platform chrome — TikTok/Reels overlay UI along the
  right edge and bottom third. Inset the usable area accordingly and bias captions into the safe band.

## Reuse (don't rebuild)

- `FocusTimeline` — the focus rects over time (already computed for auto-zoom).
- The spring camera in `VideoRenderer` — for eased crop motion.
- `CaptionBurner` — burned captions in the band.
- The `VideoRenderer` pixel pipeline (CoreImage/Metal) — reframe is a **render mode**, not a new
  encoder. Cleanest implementation: a portrait canvas + a camera that maps `FocusTimeline` into the
  portrait frame + optional layout compositing + burned captions.

`PlatformCrop` (center crop-to-fill) stays as the trivial fallback for footage with no `events.json`.

## Surface (how an agent reaches it)

Operate on the raw take + sidecar, like `--render`, so the focus data is available:

```
DemoTape --reframe <raw.mov> <WxH|preset> [--layout auto|portrait|band|split|fit-blur]
                                          [--captions <srt>] [--safe tiktok|reels|none]
                                          [--out <path>]
```

- `preset` reuses `AreaPreset` targets (9:16 → 1080×1920, 1:1, 4:5).
- `--layout auto` (default) picks per segment; an explicit layout forces one.
- `--captions <srt>` burns that SRT (already-translated is fine); omit to auto-transcribe+burn or to
  skip. Default: burn (social).
- Also expose as recipe fields (`reframeAspect`, `reframeLayout`, `safeArea`) so it composes with the
  existing recipe patch flow and the "raw+events is ground truth, styled is derived" model.

## Phasing

- **v1 — `portrait-follow` + burned captions.** The biggest single win: a 9:16 cut that keeps the
  action in frame from the recorded focus timeline, captions in a safe band. Pure crop-rect geometry
  + camera reuse; testable.
- **v2 — `band` and `split`/`stacked` layouts**, and `fit-blur` establishing shots.
- **v3 — editorial:** hook/first-3s treatment (open on the payoff), and splitting one recording into
  several short scene clips (`--split`).

## Testability

- Pure functions: timeline → segments, focus rect → crop rect in target aspect, safe-area insets,
  caption band placement. Unit-tested with synthetic `events.json` (no GUI/network), like
  `PlatformFit`/`FocusTimeline` tests.
- Pixel pipeline verified headlessly with `--frame` at segment boundaries (is the focus in frame?),
  plus dimension checks — the same way `PlatformCrop` was verified.

## Open questions for review

1. v1 scope: is `portrait-follow` + captions enough to ship first, with `band`/`split` in v2?
2. Default when no clear focus exists for a stretch — `fit-blur` establishing shot, or hold the last
   focus? (Lean: `fit-blur`.)
3. Safe-area presets: bake TikTok/Reels/Shorts insets, or a single conservative default?
4. Should reframe default to burning captions, or only when an SRT/transcript is present? (Lean:
   burn by default for social presets; skip for general aspect presets.)
