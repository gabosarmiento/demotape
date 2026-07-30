/**
 * Frame-based capture: record a demo with NO macOS Screen Recording permission.
 *
 * The native path asks the running DemoTape to capture a screen rectangle, and DemoTape's own event
 * monitor observes the clicks and keystrokes. That needs two grants and a running app, which is most
 * of the ten-minute setup before anyone sees a video.
 *
 * This backend removes both. It captures the page over the DevTools protocol
 * (`Page.startScreencast`, the same mechanism Playwright's own video recording uses) and writes the
 * `events.json` sidecar itself, from the actions it performed — it knows every click coordinate, every
 * keystroke, and every caret position, because it caused them. `DemoTape --encode-frames` then turns
 * the frames into a raw `.mov`, and `--render` styles it exactly as if the screen recorder had made
 * it: same auto-zoom, same synthetic cursor, same captions and reframe.
 *
 * Frames are the interchange rather than Playwright's built-in video because that video is WebM/VP8,
 * which AVFoundation cannot decode and DemoTape cannot add a codec for.
 *
 * What it gives up, honestly: only the page viewport is captured — no browser chrome, no desktop, no
 * second app, no webcam — and JPEG costs some fidelity. For an agent proving a web flow that's the
 * right trade; for a hand-made demo of the whole desktop, use the native path.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const clamp01 = (v) => Math.min(1, Math.max(0, v));

export class FramesCapture {
  /**
   * @param {object} o
   * @param {import('playwright').Page} o.page
   * @param {{width:number,height:number}} o.viewport  captured size, in CSS px
   * @param {string} o.dir       directory to write frames + manifest + sidecar into
   * @param {number} [o.fps]     capture rate cap
   * @param {number} [o.quality] JPEG quality 0-100
   * @param {(...a:any[])=>void} [o.log]
   */
  constructor({ page, viewport, dir, fps = 30, quality = 80, log = () => {} }) {
    this.page = page;
    this.viewport = viewport;
    this.dir = dir;
    this.framesDir = join(dir, "frames");
    this.fps = fps;
    this.quality = quality;
    this.log = log;

    this.t0 = 0;
    this.frames = [];
    this.clicks = [];
    this.keys = [];
    this.scrolls = [];
    this.cursor = [];
    this.cursorAt = { x: viewport.width / 2, y: viewport.height / 2 };
    this.session = null;
    this.stopped = true;
    this.dropped = 0;
    this.minFrameGap = 1 / Math.max(1, fps);
  }

  /** Seconds since capture began. The single clock for frames AND events, so they can't drift. */
  now() { return this.stopped ? 0 : (Date.now() - this.t0) / 1000; }

  async start() {
    mkdirSync(this.framesDir, { recursive: true });
    this.session = await this.page.context().newCDPSession(this.page);
    this.stopped = false;
    this.t0 = Date.now();

    let index = 0;
    let lastT = -Infinity;
    this.session.on("Page.screencastFrame", async (frame) => {
      // Acknowledge immediately and unconditionally: the protocol stops sending frames until the
      // previous one is acked, so a throw or an early return here silently ends the capture.
      const ack = () => this.session
        .send("Page.screencastFrameAck", { sessionId: frame.sessionId })
        .catch(() => {});
      if (this.stopped) { ack(); return; }
      const t = this.now();
      // Cap the rate. The protocol delivers a frame per paint, which on a busy page is far more than
      // the output needs and just costs disk and encode time.
      if (t - lastT < this.minFrameGap) { this.dropped++; ack(); return; }
      lastT = t;
      const name = `${String(index++).padStart(5, "0")}.jpg`;
      try {
        writeFileSync(join(this.framesDir, name), Buffer.from(frame.data, "base64"));
        this.frames.push({ path: `frames/${name}`, t: Number(t.toFixed(4)) });
      } catch (e) {
        this.dropped++;
      }
      ack();
    });

    await this.session.send("Page.startScreencast", {
      format: "jpeg",
      quality: this.quality,
      maxWidth: this.viewport.width,
      maxHeight: this.viewport.height,
      everyNthFrame: 1,
    });
    // Seed the cursor so the rendered pointer starts somewhere sensible rather than jumping in.
    this.sampleCursor(this.cursorAt.x, this.cursorAt.y, "arrow");
    this.log(`frames capture started (${this.viewport.width}x${this.viewport.height} @${this.fps}fps)`);
  }

  // ── Event recording ───────────────────────────────────────────────────────
  // Coordinates arrive in CSS pixels relative to the viewport (in headless Chromium screen coords
  // and viewport coords coincide, so the driver's existing measurement code needs no changes) and are
  // stored normalized, which is what the renderer expects.

  sampleCursor(x, y, kind = "arrow") {
    this.cursorAt = { x, y };
    this.cursor.push({
      t: Number(this.now().toFixed(4)),
      x: Number(clamp01(x / this.viewport.width).toFixed(5)),
      y: Number(clamp01(y / this.viewport.height).toFixed(5)),
      kind,
    });
  }

  /**
   * Move the pointer to (x, y) over `ms`, emitting intermediate samples.
   *
   * The samples are what the renderer draws, so a single start/end pair would teleport the pointer.
   * Easing it here reproduces what the native path gets from the app animating the real cursor — the
   * travel is what carries the viewer's eye between two points.
   */
  async glideTo(x, y, ms = 520, kind = "arrow") {
    const from = { ...this.cursorAt };
    const steps = Math.max(2, Math.round(ms / 16));
    for (let i = 1; i <= steps; i++) {
      const p = i / steps;
      const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;   // ease-in-out
      this.sampleCursor(from.x + (x - from.x) * e, from.y + (y - from.y) * e,
                        i === steps ? kind : "arrow");
      await new Promise((r) => setTimeout(r, ms / steps));
    }
  }

  click(x, y) {
    this.sampleCursor(x, y, "hand");
    this.clicks.push({
      t: Number(this.now().toFixed(4)),
      x: Number(clamp01(x / this.viewport.width).toFixed(5)),
      y: Number(clamp01(y / this.viewport.height).toFixed(5)),
      button: "left",
    });
  }

  /** One keystroke, with the caret's viewport position when it's known. */
  key(chars = "a", caret = null) {
    const k = { t: Number(this.now().toFixed(4)), keyCode: 0, chars, modifiers: [] };
    if (caret) {
      k.x = Number(clamp01(caret.x / this.viewport.width).toFixed(5));
      k.y = Number(clamp01(caret.y / this.viewport.height).toFixed(5));
    }
    this.keys.push(k);
  }

  scroll(x, y, dy) {
    this.scrolls.push({
      t: Number(this.now().toFixed(4)),
      x: Number(clamp01(x / this.viewport.width).toFixed(5)),
      y: Number(clamp01(y / this.viewport.height).toFixed(5)),
      dx: 0, dy,
    });
  }

  // ── Finish ────────────────────────────────────────────────────────────────

  /**
   * Stop capturing and write the manifest and the events sidecar.
   * @param {string} base basename for the outputs (the sidecar must be `<base>.events.json`, which is
   *                      where `--render` looks for it next to `<base>.mov`).
   */
  async stop(base = "capture") {
    if (this.stopped) return null;
    const duration = this.now();
    this.stopped = true;
    try { await this.session.send("Page.stopScreencast"); } catch {}
    try { await this.session.detach(); } catch {}

    const manifestPath = join(this.dir, "manifest.json");
    writeFileSync(manifestPath, JSON.stringify({
      width: this.viewport.width,
      height: this.viewport.height,
      fps: this.fps,
      // The capture's real length, which is longer than the last frame's timestamp whenever the page
      // stopped repainting before the end (it always does — the closing beat is a still result). The
      // encoder holds the final image out to here, so the ending isn't cut off and the last narration
      // line still has video under it.
      duration: Number(duration.toFixed(3)),
      frames: this.frames,
    }, null, 2));

    // The same shape DemoTape's own recorder writes, so --render can't tell the difference. The
    // captured viewport IS the display here, which is what the normalized coordinates are relative to.
    const sidecar = join(this.dir, `${base}.events.json`);
    writeFileSync(sidecar, JSON.stringify({
      version: 1,
      // Without the milliseconds. JS always emits them ("…T02:00:00.000Z") and Swift's `.iso8601`
      // decoding strategy uses `.withInternetDateTime`, which does not accept a fractional second —
      // so the full form makes the whole sidecar fail to decode with a confusing "Expected date
      // string to be ISO8601-formatted".
      startedAt: new Date(this.t0).toISOString().replace(/\.\d{3}Z$/, "Z"),
      duration: Number(duration.toFixed(3)),
      capturedKeystrokes: this.keys.length > 0,
      eventTimeOffset: 0,          // one clock for frames and events, so there is nothing to correct
      display: {
        pointWidth: this.viewport.width, pointHeight: this.viewport.height,
        pixelWidth: this.viewport.width, pixelHeight: this.viewport.height, scale: 1,
      },
      cursor: this.cursor,
      clicks: this.clicks,
      scrolls: this.scrolls,
      keys: this.keys,
    }, null, 2));

    this.log(`frames capture stopped: ${this.frames.length} frames` +
             (this.dropped ? ` (${this.dropped} dropped/rate-capped)` : "") +
             `, ${this.clicks.length} click(s), ${this.keys.length} key(s), ` +
             `${duration.toFixed(2)}s`);
    return { manifestPath, sidecar, duration, frames: this.frames.length };
  }
}
