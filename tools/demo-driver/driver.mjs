#!/usr/bin/env node
// DemoTape demo driver — AI-led, self-verifying demo generation.
//
// A demo is a list of SCENES; each has a spoken line (`say`), the on-screen `steps` to do while
// saying it, and an optional `expect` (the post-condition that proves the action worked). The
// driver runs the whole thing hands-off and PROVES the result matches the script before presenting
// it — like a test suite gating a release:
//   0. synthesize each scene's line (so it knows each line's length),
//   1. launch a headed Chromium at a known rectangle and navigate,
//   2. tell DemoTape to record that rectangle,
//   3. per scene: line leads → action fires → wait for load → ASSERT the expected post-condition
//      (Playwright), moving the real cursor so DemoTape shows it,
//   4. stop + auto-render, lay each line at its scene's start,
//   5. VERIFY the render: a vision model checks each scene's frame matches its narration,
//   6. if any assertion or verification failed, retry (bounded); only presents a passing demo.
//
// Outside the DemoTape app. Usage:  node driver.mjs path/to/demo.json

import { chromium } from "playwright";
import { execFile, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, appendFileSync, statSync, readdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONTROL_JSON = join(homedir(), "Movies", "DemoTape", ".demotape", "control.json");
const LOG_FILE = join(__dirname, "driver.log");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function log(...a) {
  const line = `[${new Date().toISOString()}] ${a.join(" ")}`;
  console.log("[demo-driver]", ...a);
  try { appendFileSync(LOG_FILE, line + "\n"); } catch {}
}

function loadConfig() {
  const path = process.argv[2] && !process.argv[2].startsWith("--") ? resolve(process.argv[2]) : join(__dirname, "demo.example.json");
  if (!existsSync(path)) { console.error("config not found:", path); process.exit(1); }
  const cfg = JSON.parse(readFileSync(path, "utf8"));
  cfg.viewport = { x: 100, y: 90, width: 1280, height: 800, ...(cfg.viewport || {}) };
  cfg.stepPauseMs = cfg.stepPauseMs ?? 900;
  cfg.showCursor = cfg.showCursor !== false;
  // OS-level clicks are now the DEFAULT (opt out with "osClick": false).
  //
  // This used to default to off, and that single flag is why earlier demos came out visually flat:
  // Playwright clicks are synthetic browser events, invisible to DemoTape's global event monitor, so
  // events.json recorded ZERO clicks and the auto-zoom never fired once — a verified-correct video
  // that was one motionless shot end to end. Clicks are routed through the running app, which holds
  // the Accessibility grant, so they register and drive the zoom.
  cfg.osClick = cfg.osClick !== false;
  // How long the cursor takes to travel to a target (eased + arced inside the app). Long enough to
  // read as a hand, short enough not to stall the narration.
  cfg.moveMs = cfg.moveMs ?? 520;
  // Mean ms per character for `type` steps. ~55ms is a brisk but human ~55 wpm; raise it to make the
  // typing more deliberate, lower it if a long prompt is eating the scene's time budget.
  cfg.typeMs = cfg.typeMs ?? 55;
  // Real OS keystrokes by DEFAULT (opt out with "osType": false, or per-step "browserType": true).
  // Same reasoning as osClick: DemoTape's auto-zoom is driven by clicks and keys, so typing it can't
  // observe leaves the camera wide while the text appears.
  cfg.osType = cfg.osType !== false;
  cfg.actionLeadFraction = cfg.actionLeadFraction ?? 0.7;
  cfg.tailMs = cfg.tailMs ?? 1600;   // extra recording after the last line so it's never clipped
  cfg.maxAttempts = cfg.maxAttempts ?? 2;
  cfg.verify = cfg.verify !== false;
  cfg.demotapeBin = cfg.demotapeBin
    ? resolve(cfg.demotapeBin)
    : resolve(__dirname, "..", "..", ".build", "release", "DemoTape");
  // Resolve profile paths against the CONFIG's directory, not the shell's working directory.
  // Resolving against the CWD silently creates a NEW empty profile when the driver is run from
  // somewhere else — which looks exactly like an expired session: the prewarm lands on the login
  // page and the take records a sign-in screen instead of the app.
  if (cfg.userDataDir) cfg.userDataDir = resolve(dirname(path), cfg.userDataDir);
  if (!Array.isArray(cfg.scenes) || cfg.scenes.length === 0) {
    const say = cfg.narration || (cfg.narrationFile ? readFileSync(resolve(cfg.narrationFile), "utf8") : "");
    cfg.scenes = [{ say, steps: cfg.steps || [] }];
  }
  return { cfg, path };
}

function openURL(url) { execFileSync("/usr/bin/open", [url]); }
function readControl() { try { return JSON.parse(readFileSync(CONTROL_JSON, "utf8")); } catch { return null; } }

async function waitForState(state, timeoutMs = 20000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const s = readControl();
    if (s && s.state === state) return s;
    await sleep(250);
  }
  throw new Error(`timed out waiting for DemoTape state="${state}"`);
}

function measureDuration(file) {
  try {
    const out = execFileSync("/usr/bin/afinfo", [file], { encoding: "utf8" });
    const m = out.match(/estimated duration:\s*([\d.]+)/i);
    return m ? parseFloat(m[1]) : 0;
  } catch { return 0; }
}

function osCursor(cfg, action, x, y, ms) {
  // Route through the RUNNING installed app (holds the Accessibility grant + is the recording
  // process) so synthetic clicks actually register and trigger auto-zoom. The standalone CLI
  // binary is a separate unsigned executable the user never granted, so its CGEventPost no-ops.
  //
  // Moves are ANIMATED (cursor/glide with a duration), not warped. A warp reads as a robot on
  // video and, worse, gives the eye nothing to follow between two points — the travel is what
  // carries attention. The easing/arc/overshoot is done inside the app, so one URL per move.
  const glide = action === "move" && ms > 0;
  const url = glide
    ? `demotape://cursor/glide?x=${Math.round(x)}&y=${Math.round(y)}&ms=${Math.round(ms)}`
    : `demotape://cursor/${action}?x=${Math.round(x)}&y=${Math.round(y)}`;
  try { execFileSync("/usr/bin/open", [url]); }
  catch (e) { log("cursor failed:", e.message); }
}

/**
 * Screen point for an element. `fx` is the fraction across its width (0.5 = centre).
 *
 * Text fields want `fx` near the LEFT edge, not the centre. DemoTape anchors its zoom on the click,
 * so clicking the middle of a wide input frames the middle of an empty box — and the sentence then
 * grows leftwards out of shot. Clicking where the text begins is also what a person does: you aim at
 * the caret, not the geometric centre.
 */
async function elementScreenPoint(page, selector, fx = 0.5) {
  try {
    const el = page.locator(selector).first();
    await el.scrollIntoViewIfNeeded({ timeout: 5000 });
    const box = await inkRect(page, selector) ?? await el.boundingBox();
    if (!box) return null;
    const w = await page.evaluate(() => ({ sx: window.screenX, sy: window.screenY, oh: outerHeight, ih: innerHeight }));
    // Keep a small inset so the point never sits on the border itself.
    const offsetX = Math.min(Math.max(box.width * fx, 14), box.width - 14);
    return { x: w.sx + box.x + offsetX, y: w.sy + (w.oh - w.ih) + box.y + box.height / 2 };
  } catch { return null; }
}

async function elementScreenCenter(page, selector) {
  return elementScreenPoint(page, selector, 0.5);
}

async function moveCursorToSelector(page, cfg, selector) {
  if (!cfg.showCursor || !selector) return null;
  const c = await elementScreenCenter(page, selector);
  if (!c) return c;

  // Aim slightly off dead-centre: people don't hit the exact middle of a button, and identical
  // pixel-perfect landings across a whole demo are a tell.
  //
  // CLAMPED to the element's own box, though. Unclamped jitter misses narrow targets — an inline
  // link a few pixels tall — and a missed OS click looks like the app ignored you.
  const box = await elementBox(page, selector);
  const jitter = cfg.aimJitter ?? 4;
  let tx = c.x + (Math.random() * 2 - 1) * jitter;
  let ty = c.y + (Math.random() * 2 - 1) * jitter;
  if (box) {
    const padX = Math.min(6, Math.max(1, box.width / 4));
    const padY = Math.min(4, Math.max(1, box.height / 4));
    tx = Math.min(Math.max(tx, box.left + padX), box.right - padX);
    ty = Math.min(Math.max(ty, box.top + padY), box.bottom - padY);
  }
  osCursor(cfg, "move", tx, ty, cfg.moveMs);
  // Wait out the glide, then a beat to aim — a human lands, settles, then presses.
  await sleep(cfg.moveMs + 160);
  return { x: tx, y: ty };
}

// Resolve a gesture target to a screen point. Prefer a selector (grounded to a real element);
// fall back to normalized viewport coords (nx/ny in 0…1) or absolute screen x/y.
async function gesturePoint(page, cfg, g) {
  if (g.selector) {
    const c = await elementScreenCenter(page, g.selector);
    if (c) return c;
  }
  const { x, y, width, height } = cfg.viewport;
  if (typeof g.nx === "number" && typeof g.ny === "number") {
    return { x: x + g.nx * width, y: y + g.ny * height };
  }
  if (typeof g.x === "number" && typeof g.y === "number") return { x: g.x, y: g.y };
  return null;
}

// Play a scene's attention gestures spread evenly across `windowMs`. The cursor becomes an
// attention pointer: it glides to each region as the narration talks about it (point), and can
// emphasize with a soft click (click: true) so DemoTape auto-zooms on that spot. This is what
// makes the motion feel human — a few unhurried points that trace what's being said — rather than
// one robotic click on a button.
/**
 * Attention gestures: the cursor used as a POINTER, which is what people actually do with it.
 *
 * The cursor is the only thing in a screen recording that can say "look here". A demo that moves it
 * solely to press buttons wastes it — the viewer scans a whole screen while the narration talks
 * about one value in a corner. Each gesture is therefore a way of directing the eye, and because
 * DemoTape zooms on real clicks, an emphasis click also reframes the shot around what's being said.
 *
 * Kinds:
 *   point     — glide there and settle (the default), with a little idle drift
 *   circle    — trace a small circle around it: "this whole area here"
 *   underline — sweep left→right across it, like running a finger under a line of text
 *   select    — glide there and actually highlight the text being read aloud
 *
 * `click: true` adds an emphasis click, which triggers the zoom. Prefer non-navigating elements
 * (headings, labels, values) for pure emphasis, so a "look here" doesn't change the page.
 */
async function playGestures(page, cfg, gestures, windowMs) {
  if (!cfg.showCursor || !gestures || !gestures.length) { await sleep(Math.max(0, windowMs)); return; }
  const slice = Math.max(0, windowMs) / gestures.length;
  for (const g of gestures) {
    const started = Date.now();
    const p = await gesturePoint(page, cfg, g);
    if (p) {
      // Give the glide most of its slice so the travel is visible, but never longer than the
      // gesture's share of the spoken line.
      const travel = Math.min(cfg.moveMs, Math.max(220, slice * 0.5));
      osCursor(cfg, "move", p.x, p.y, travel);
      await sleep(Math.min(slice * 0.45, travel + 160));   // let the glide land before any click
      if (g.click && cfg.osClick) {
        // Same staleness risk as a real click: the aim was measured before the glide.
        const aim = g.selector ? await settleAimOnSelector(page, cfg, g.selector, p) : p;
        osCursor(cfg, "click", aim.x, aim.y);
      }

      const box = g.selector ? await elementBox(page, g.selector) : null;
      // Shape-based gestures are handed to the app as ONE path and swept in a single motion. Issuing
      // them as a series of short moves left a visible seam at every leg — the cursor stuttered around
      // a circle instead of drawing it.
      const shape = g.kind === "auto" ? pickGestureShape(box) : g.kind;
      if (SHAPE_GESTURES.has(shape) && box) {
        const pts = gesturePath(shape, p, box, g);
        osPath(cfg, pts, g.sweepMs ?? shapeDurationMs(shape, box));
        await sleep((g.sweepMs ?? shapeDurationMs(shape, box)) + 200 + (g.dwellMs ?? 0));
        continue;
      }
      switch (g.kind) {
        case "circle": {
          // A hand-drawn loop, never the same twice. A perfect ellipse traced at constant speed is
          // the most obviously robotic thing a cursor can do, so every property varies: where the
          // loop starts, which way it goes, how round it is, how it tilts, and how the speed ebbs
          // through it. The radius also wobbles per step, the way a wrist does.
          const rx0 = Math.min(box ? box.width / 2 + 14 : 44, 95);
          const ry0 = Math.min(box ? box.height / 2 + 12 : 28, 64);
          const startAngle = Math.random() * Math.PI * 2;
          const direction = Math.random() < 0.5 ? 1 : -1;      // clockwise or not
          const tilt = (Math.random() * 2 - 1) * 0.35;         // radians of lean
          const squash = 0.85 + Math.random() * 0.35;          // never perfectly round
          const sweep = Math.PI * 2 * (0.9 + Math.random() * 0.35);  // slightly over/under a loop
          const steps = 9 + Math.floor(Math.random() * 4);
          for (let i = 1; i <= steps; i++) {
            const u = i / steps;
            // Ease in and out of the loop rather than tracing at constant speed.
            const eased = u < 0.5 ? 2 * u * u : 1 - Math.pow(-2 * u + 2, 2) / 2;
            const a = startAngle + direction * eased * sweep;
            const wobble = 1 + (Math.random() * 2 - 1) * 0.08;
            const ex = Math.cos(a) * rx0 * wobble;
            const ey = Math.sin(a) * ry0 * squash * wobble;
            // Rotate the ellipse so the loop isn't axis-aligned.
            const x = p.x + ex * Math.cos(tilt) - ey * Math.sin(tilt);
            const y = p.y + ex * Math.sin(tilt) + ey * Math.cos(tilt);
            const legMs = 90 + Math.random() * 70;
            osCursor(cfg, "move", x, y, legMs);
            await sleep(legMs + 15);
          }
          break;
        }
        case "underline": {
          // Left→right, the direction reading goes — a finger under a line. Swept in a few uneven
          // legs with a slight vertical waver rather than one straight glide, because a single
          // perfectly level slide is the other obvious robot tell.
          if (box) {
            const y0 = p.y + (Math.random() * 2 - 1) * 3;
            osCursor(cfg, "move", box.left + 8 + Math.random() * 6, y0, 200);
            await sleep(230);
            const total = g.sweepMs ?? 900;
            const legs = 3 + Math.floor(Math.random() * 2);
            const span = (box.right - 12) - (box.left + 8);
            for (let i = 1; i <= legs; i++) {
              // Uneven progress: reading isn't metronomic either.
              const u = Math.min(1, (i / legs) * (0.85 + Math.random() * 0.3));
              const legMs = (total / legs) * (0.75 + Math.random() * 0.5);
              osCursor(cfg, "move", box.left + 8 + span * u,
                       y0 + (Math.random() * 2 - 1) * 2.5, legMs);
              await sleep(legMs + 25);
            }
          }
          break;
        }
        case "select": {
          // A real selection, so the words being narrated are visibly highlighted.
          try { await page.locator(g.selector).first().selectText({ timeout: 3000 }); } catch {}
          await sleep(g.dwellMs ?? 700);
          break;
        }
        default:
          await microDrift(cfg, p);
      }
      if (g.dwellMs && g.kind !== "select") await sleep(g.dwellMs);
    }
    const rest = slice - (Date.now() - started);
    if (rest > 0) await sleep(rest);
  }
}

/**
 * The gesture vocabulary — how the cursor says "look at this".
 *
 * A single move-in-a-circle is not enough: what reads naturally depends on the SHAPE of the thing
 * being pointed at and on what you mean by pointing at it. A line of text wants a sweep along it. A
 * number wants a loop around it. A card wants its outline traced. A value you're contrasting wants a
 * bracket beside it. So the driver carries several, and `"kind": "auto"` lets it choose by geometry.
 *
 * Every shape is generated as a point list and handed to the app as one path, so it's drawn in a
 * single eased motion (see `demotape://cursor/path`). Every shape is also randomised — start angle,
 * direction, radius wobble, corner slop — because the giveaway isn't the shape, it's repetition.
 */
const SHAPE_GESTURES = new Set(["ellipse", "box", "bracket", "zigzag", "sweep", "check"]);

/** Pick a shape that suits the target's proportions. */
function pickGestureShape(box) {
  if (!box) return "ellipse";
  const ratio = box.width / Math.max(1, box.height);
  const candidates = ratio > 6 ? ["sweep", "zigzag", "sweep"]        // a line of text
    : ratio > 2.2 ? ["ellipse", "box", "sweep"]                       // a row, a tile, a button
    : ["ellipse", "box", "bracket"];                                  // a block or a card
  return candidates[Math.floor(Math.random() * candidates.length)];
}

/** Longer shapes need longer to draw; a hand doesn't sprint round a big card. */
function shapeDurationMs(shape, box) {
  const span = box ? Math.max(box.width, box.height) : 120;
  const base = { sweep: 850, zigzag: 1150, ellipse: 1050, box: 1250, bracket: 900, check: 700 }[shape] || 1000;
  return Math.round(base * (0.85 + Math.min(1.4, span / 700)));
}

const jitter = (amount) => (Math.random() * 2 - 1) * amount;

/** Point list for a gesture shape, in screen coordinates. */
function gesturePath(shape, p, box, g = {}) {
  const pad = 10;
  const left = box.left - pad, right = box.right + pad;
  const top = box.top - pad, bottom = box.bottom + pad;
  const midY = (box.top + box.bottom) / 2;
  const pts = [];

  switch (shape) {
    case "sweep": {
      // Along a line of text, the way you'd run a finger under it — with a slight bow, since nobody
      // draws a ruler-straight line.
      const y = midY + jitter(2);
      const bow = jitter(3.5);
      for (let i = 0; i <= 6; i++) {
        const u = i / 6;
        pts.push({ x: box.left + 6 + (box.width - 12) * u, y: y + Math.sin(u * Math.PI) * bow });
      }
      break;
    }
    case "zigzag": {
      // A scribbled highlight over text: back and forth along it, like a marker.
      const passes = 2 + Math.floor(Math.random() * 2);
      const amp = Math.min(box.height * 0.32, 9);
      for (let pass = 0; pass < passes; pass++) {
        const forward = pass % 2 === 0;
        for (let i = 0; i <= 5; i++) {
          const u = forward ? i / 5 : 1 - i / 5;
          pts.push({ x: box.left + 6 + (box.width - 12) * u,
                     y: midY + (i % 2 ? amp : -amp) * 0.6 + jitter(1.5) });
        }
      }
      break;
    }
    case "box": {
      // Trace the card's outline. Corners are rounded by the spline, and the loop starts at a random
      // corner so two boxes in one demo don't look stamped.
      const corners = [
        { x: left, y: top }, { x: right, y: top }, { x: right, y: bottom }, { x: left, y: bottom },
      ];
      const start = Math.floor(Math.random() * 4);
      const dir = Math.random() < 0.5 ? 1 : -1;
      for (let i = 0; i <= 4; i++) {
        const c = corners[(start + i * dir + 8) % 4];
        pts.push({ x: c.x + jitter(4), y: c.y + jitter(4) });
      }
      break;
    }
    case "bracket": {
      // A bracket down one side: "this whole group". Cheaper than a box and reads as grouping.
      const onLeft = Math.random() < 0.5;
      const x = onLeft ? left : right;
      const inset = (onLeft ? 12 : -12);
      pts.push({ x: x + inset, y: top + jitter(3) });
      pts.push({ x: x + jitter(2), y: top + 6 });
      pts.push({ x: x + jitter(2), y: bottom - 6 });
      pts.push({ x: x + inset, y: bottom + jitter(3) });
      break;
    }
    case "check": {
      // A tick over something confirmed — for a line about something that passed or was approved.
      pts.push({ x: box.left + box.width * 0.28, y: midY });
      pts.push({ x: box.left + box.width * 0.42, y: box.bottom - 4 });
      pts.push({ x: box.left + box.width * 0.72, y: box.top + 2 });
      break;
    }
    case "ellipse":
    default: {
      // A loop around it. Never the same twice: start angle, direction, tilt, squash and radius all
      // vary, and the spline smooths what's left.
      const rx = Math.min(box.width / 2 + 14, 110);
      const ry = Math.min(box.height / 2 + 12, 70);
      const startAngle = Math.random() * Math.PI * 2;
      const dir = Math.random() < 0.5 ? 1 : -1;
      const tilt = jitter(0.3);
      const squash = 0.85 + Math.random() * 0.3;
      const sweep = Math.PI * 2 * (0.92 + Math.random() * 0.22);
      const steps = 10;
      for (let i = 0; i <= steps; i++) {
        const a = startAngle + dir * (i / steps) * sweep;
        const wob = 1 + jitter(0.06);
        const ex = Math.cos(a) * rx * wob, ey = Math.sin(a) * ry * squash * wob;
        pts.push({ x: p.x + ex * Math.cos(tilt) - ey * Math.sin(tilt),
                   y: p.y + ex * Math.sin(tilt) + ey * Math.cos(tilt) });
      }
      break;
    }
  }
  return pts;
}

/** Hand a whole gesture path to the app, which sweeps it as one eased motion. */
function osPath(cfg, points, ms) {
  if (!points || points.length < 2) return;
  const pts = points.map((q) => `${Math.round(q.x)},${Math.round(q.y)}`).join(";");
  try {
    execFileSync("/usr/bin/open", [`demotape://cursor/path?pts=${pts}&ms=${Math.round(ms)}`]);
  } catch (e) { log("cursor path failed:", e.message); }
}

/**
 * Re-measure the target right before pressing, and correct the aim if it drifted.
 *
 * The aim point is taken, then the cursor glides for half a second, then it clicks — and in between
 * the page can reflow (a card renders, a banner collapses, a live region updates). The click then
 * lands where the button *used to be*, which in one recording put the pointer in the gap between two
 * buttons: a click on nothing, on camera, right as the narration said "I'll grant it".
 *
 * Cheap because it only corrects when the aim actually fell outside the fresh box — a matching
 * layout keeps the human jitter from `moveCursorToSelector` instead of snapping to dead centre.
 */
async function settleAimOnSelector(page, cfg, selector, aimed, fx = 0.5) {
  if (!aimed || !selector) return aimed;
  const box = await elementBox(page, selector);
  if (!box) return aimed;
  const inside = aimed.x >= box.left + 1 && aimed.x <= box.right - 1 &&
                 aimed.y >= box.top + 1 && aimed.y <= box.bottom - 1;
  if (inside) return aimed;
  const fresh = await elementScreenPoint(page, selector, fx);
  if (!fresh) return aimed;
  log(`  ${selector} moved under the cursor — re-aiming before the click`);
  osCursor(cfg, "move", fresh.x, fresh.y, 220);
  await sleep(280);
  return fresh;
}

/**
 * The rect of the WORDS inside a target, not the box around them.
 *
 * Pointing at a container is how a demo ends up clicking nothing. A card or a list is mostly padding
 * and gaps, so its geometric centre is often blank — in one take the emphasis click for "I'll approve
 * it" landed in the space between the Grant and Deny buttons, on camera, because the gesture targeted
 * the surrounding list. The pointer should go where the ink is.
 *
 * So: if the element paints its own text, use it. Otherwise walk down to the first visible descendant
 * that does. A button whose label sits in a span resolves to the span (still inside the button); an
 * input has no text and no children, so it is left alone.
 *
 * Resolved through the Playwright locator, not `querySelector`, so `:has-text(...)` selectors work.
 */
async function inkRect(page, selector) {
  try {
    return await page.locator(selector).first().evaluate((el) => {
      const paints = (n) => {
        const r = n.getBoundingClientRect(), st = getComputedStyle(n);
        return r.width > 8 && r.height > 6 && st.visibility !== "hidden" &&
               st.display !== "none" && parseFloat(st.opacity || "1") > 0.05;
      };
      const ownText = (n) =>
        Array.from(n.childNodes).some((c) => c.nodeType === 3 && c.textContent.trim().length > 0);
      let target = el;
      if (!ownText(el) && el.children.length) {
        const queue = Array.from(el.children);
        while (queue.length) {
          const n = queue.shift();
          if (paints(n) && ownText(n)) { target = n; break; }
          queue.push(...Array.from(n.children));
        }
      }
      const r = target.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    });
  } catch { return null; }
}

/** Element rect in SCREEN coordinates, for gestures that need its extent rather than a point. */
async function elementBox(page, selector) {
  try {
    const box = await inkRect(page, selector) ?? await page.locator(selector).first().boundingBox();
    if (!box) return null;
    const w = await page.evaluate(() => ({ sx: window.screenX, sy: window.screenY, oh: outerHeight, ih: innerHeight }));
    const top = w.sy + (w.oh - w.ih) + box.y;
    return { left: w.sx + box.x, right: w.sx + box.x + box.width, top,
             bottom: top + box.height, width: box.width, height: box.height };
  } catch { return null; }
}

/**
 * A small idle drift. A hand never parks a pointer perfectly still, and a frozen cursor between
 * actions is one of the clearest tells that a recording was scripted.
 */
async function microDrift(cfg, p, amount = 9) {
  osCursor(cfg, "move", p.x + (Math.random() * 2 - 1) * amount,
           p.y + (Math.random() * 2 - 1) * amount, 240);
  await sleep(300);
}

/**
 * Types text the way a person does, so a demo doesn't look like a script pasting a prompt.
 *
 * Real typing isn't a metronome, which is why a fixed per-character delay still reads as synthetic.
 * Three things make it convincing:
 *   - jitter per keystroke (people are uneven),
 *   - a longer pause after sentence punctuation and a shorter one after spaces (you think in words,
 *     not letters),
 *   - an occasional brief hesitation mid-sentence.
 *
 * Tuned by `typeMs` (mean ms per character, default 55). Set `instant: true` on a step to opt out.
 */
async function humanType(page, cfg, step) {
  const text = step.text ?? "";
  const el = page.locator(step.selector).first();

  // Land a REAL OS click on the field first: it focuses the input, and it anchors DemoTape's
  // auto-zoom, so the camera is already on the field before a character appears.
  //
  // Aim near the LEFT of the field (where the caret and the first word will be), not its centre.
  // The zoom holds on this exact point for the whole sentence, so a centred anchor on a wide input
  // pushes the text off the left edge of the framed shot as it grows.
  const c = cfg.showCursor
    ? await elementScreenPoint(page, step.selector, step.aimX ?? 0.06)
    : null;
  if (c) { osCursor(cfg, "move", c.x, c.y, cfg.moveMs); await sleep(cfg.moveMs + 160); }
  if (cfg.osClick && c) osCursor(cfg, "click", c.x, c.y);
  else await el.click({ timeout: step.timeout ?? 8000 });
  await el.fill("");                       // start from empty, so re-runs don't append
  if (step.instant) { await el.fill(text); return; }

  const base = step.typeMs ?? cfg.typeMs ?? 55;
  await sleep(260);                        // a beat before starting, as if reading the field

  // Type in the BROWSER, but tell DemoTape that typing is happening.
  //
  // Two constraints force this split. Browsers discard synthetic key events that carry no virtual
  // keycode, so posting real OS keystrokes at Chromium enters nothing — and since OS keys go to
  // whichever window has system focus, they can land in another app entirely while the field stays
  // empty (which is exactly the "it sends but the text never shows" bug). So the visible text has to
  // come from Playwright. But then no KeySample exists, and DemoTape's FocusTimeline only holds the
  // camera on the focused field *while keys are arriving* — so the zoom snapped in on the click and
  // then drifted off mid-sentence.
  //
  // `demotape://typing` records the activity without posting anything: the anchor still comes from
  // the real OS click just above, so the camera holds on the field for the whole sentence, exactly
  // as it does when a human types.
  const punctuation = (text.match(/[.?!,;:]/g) || []).length;
  const expectedMs = text.length * base + punctuation * base * 4;

  // Report typing activity as a HEARTBEAT while typing, not as one upfront estimate.
  //
  // An estimate always drifts: the browser types with jitter and pauses, so the reported activity
  // ran out before the sentence finished and the zoom fell back to a wide shot mid-thought. Each
  // beat also carries the CARET's real position, measured from the field's own text, so the camera
  // follows the words as they grow instead of staring at where the field started.
  const box0 = await elementBox(page, step.selector);
  const caretPoint = async () => {
    if (!box0) return null;
    // Measure the rendered width of the text so far, in the field's own font.
    const w = await page.evaluate((sel) => {
      const el = document.querySelector(sel);
      if (!el) return 0;
      const cs = getComputedStyle(el);
      const c = document.createElement("canvas").getContext("2d");
      c.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
      const padLeft = parseFloat(cs.paddingLeft) || 0;
      return Math.min(c.measureText(el.value || "").width + padLeft, el.clientWidth - 8);
    }, step.selector).catch(() => 0);
    return { x: box0.left + 6 + w, y: box0.top + box0.height / 2 };
  };

  let heartbeat = null;
  if (cfg.osType && !step.browserType) {
    const cps = 1000 / base;
    // Each beat covers exactly its own interval — no overlap. Overlapping batches interleave stale
    // and fresh caret positions in the event stream, and the camera then jitters between them
    // instead of panning.
    const beatMs = 700;
    const beat = async () => {
      const p = await caretPoint();
      const q = p ? `&x=${Math.round(p.x)}&y=${Math.round(p.y)}` : "";
      try {
        execFileSync("/usr/bin/open",
                     [`demotape://typing?chars=${Math.max(2, Math.round(cps * beatMs / 1000))}`
                      + `&cps=${cps.toFixed(1)}${q}`]);
      } catch {}
    };
    await beat();
    heartbeat = setInterval(beat, beatMs);
  }

  for (const ch of text) {
    await page.keyboard.type(ch);
    let d = base * (0.6 + Math.random() * 0.9);
    if (".?!".includes(ch)) d += base * 6;         // end of a thought
    else if (",;:—".includes(ch)) d += base * 3;   // a clause break
    else if (ch === " " && Math.random() < 0.08) d += base * 4;   // brief hesitation
    await sleep(d);
  }
  if (heartbeat) clearInterval(heartbeat);

  const got = (await el.inputValue().catch(() => "")).trim();
  if (got !== text.trim()) log(`  typing landed "${got.slice(0, 40)}…" (expected the full line)`);
  await sleep(340);                        // pause before sending, as if re-reading it
  return expectedMs;
}

async function runStep(page, step, cfg) {
  const wait = step.pauseMs ?? cfg.stepPauseMs;
  switch (step.action) {
    case "goto": await page.goto(step.url, { waitUntil: "domcontentloaded", timeout: 45000 }); break;
    case "wait": await sleep(step.ms ?? 1000); return;
    case "click": {
      const before = page.url();
      let c = await moveCursorToSelector(page, cfg, step.selector);
      if (cfg.osClick && c) {
        c = await settleAimOnSelector(page, cfg, step.selector, c);
        osCursor(cfg, "click", c.x, c.y);
        // `mustAct: true` means this click has to DO something (follow a link, submit a form). An OS
        // click can miss — a narrow target, a late reflow, an overlay — and a miss is silent: the
        // demo carries on as if the app ignored the user. So verify it navigated and, if not, click
        // through the browser to save the take. The zoom came from the real click either way.
        //
        // Opt-in on purpose: retrying blindly would double-fire, and an emphasis click on a heading
        // legitimately changes nothing while a second click on a submit button is a real action.
        if (step.mustAct) {
          // POLL for the navigation rather than checking once. A single check after ~900ms calls a
          // slow-but-successful click a failure, and the "rescue" click then re-submits the form —
          // granting an approval twice, sending a message twice. Waiting the full window costs
          // nothing when the click worked, because the poll exits as soon as the URL changes.
          const deadline = Date.now() + (step.settleMs ?? 3000);
          while (page.url() === before && Date.now() < deadline) await sleep(200);
          if (page.url() === before) {
            log(`  os-click did not take effect on ${step.selector} — clicking through the browser`);
            await page.click(step.selector, { timeout: step.timeout ?? 8000 }).catch(() => {});
          }
        }
      } else {
        await page.click(step.selector, { timeout: step.timeout ?? 8000 });
      }
      break;
    }
    // `type` types like a person, character by character. `fill` pastes instantly.
    //
    // This matters more than it sounds for a demo: the whole premise is a human talking to an agent,
    // and a prompt that materialises in one frame reads as a script pasting text, not someone
    // writing. Progressive typing also gives the viewer time to READ the prompt before the answer
    // arrives, which is exactly when you want them reading it.
    //
    // Use `fill` for setup fields nobody is meant to watch (a sign-in box, a long YAML blob) and
    // `type` for anything the story is about.
    case "type": await humanType(page, cfg, step); break;
    case "fill": await moveCursorToSelector(page, cfg, step.selector); await page.fill(step.selector, step.text ?? "", { timeout: step.timeout ?? 8000 }); break;
    case "press": await page.keyboard.press(step.key ?? "Enter"); break;
    case "hover": await moveCursorToSelector(page, cfg, step.selector); await page.hover(step.selector, { timeout: step.timeout ?? 8000 }); break;
    case "scroll": await page.mouse.wheel(0, step.y ?? 600); break;
    case "waitFor": await page.waitForSelector(step.selector, { timeout: step.timeout ?? 8000 }); break;
    case "expand": await page.evaluate((sel) => {   // force a <details> open (idempotent)
        const el = document.querySelector(sel);
        const det = el && (el.tagName === "DETAILS" ? el : el.closest("details"));
        if (det) det.open = true;
      }, step.selector); break;
    case "narrate": break;
    default: log("unknown step:", JSON.stringify(step));
  }
  await sleep(wait);
}

// Record-time assertion: proves the scene's action produced the expected state (the "test").
async function checkExpect(page, expect) {
  if (!expect) return { ok: true, reason: "no assertion" };
  try {
    if (expect.urlContains) {
      const u = page.url();
      if (!u.includes(expect.urlContains)) return { ok: false, reason: `url "${u}" missing "${expect.urlContains}"` };
    }
    if (expect.visible) await page.waitForSelector(expect.visible, { state: "visible", timeout: expect.timeout ?? 8000 });
    if (expect.text) await page.waitForSelector(`text=${expect.text}`, { timeout: expect.timeout ?? 8000 });
    // `text=` matches rendered text, NOT an input's value — asserting a typed prompt needs the
    // field's value, so typing scenes use `value: { selector, is }`.
    if (expect.value) {
      const { selector, is } = expect.value;
      const want = (is ?? "").trim();
      const deadline = Date.now() + (expect.timeout ?? 8000);
      let got = "";
      while (Date.now() < deadline) {
        got = (await page.locator(selector).first().inputValue().catch(() => "")).trim();
        if (got === want) break;
        await sleep(150);
      }
      if (got !== want) return { ok: false, reason: `value of ${selector} is "${got.slice(0, 48)}"` };
    }
    return { ok: true, reason: "ok" };
  } catch (e) { return { ok: false, reason: (e.message || "assertion failed").split("\n")[0] }; }
}

// One full attempt. Synthesized `scenes` (with .clip/.dur) are passed in so TTS isn't repeated.
async function runOnce(cfg, scenes) {
  const { x, y, width, height } = cfg.viewport;
  const args = [
    `--window-position=${Math.round(x)},${Math.round(y)}`,
    `--window-size=${Math.round(width)},${Math.round(height)}`,
    "--no-first-run", "--no-default-browser-check",
  ];
  log("launching Chromium at", `${width}x${height}+${x}+${y}`);
  // `userDataDir` reuses a PERSISTENT browser profile, which is what makes demos of authenticated
  // apps possible: sign in once beforehand and the session is already live, so no credentials are
  // typed on camera and no hosted login page (Clerk, Auth0, …) has to be automated mid-take.
  let browser = null, context, page;
  if (cfg.userDataDir) {
    context = await chromium.launchPersistentContext(resolve(cfg.userDataDir), {
      headless: false, viewport: null, args,
    });
    page = context.pages()[0] || await context.newPage();
  } else {
    browser = await chromium.launch({ headless: false, args });
    context = await browser.newContext({ viewport: null });
    page = await context.newPage();
  }
  // Visit any prewarm URLs BEFORE recording starts. Hosted auth (Clerk, Auth0, …) bounces through a
  // redirect handshake on first navigation, and a cold page paints late — both land on camera as a
  // sign-in screen or a blank flash if the take is the first visit. Doing it off-camera means the
  // scene that shows the page gets it already warm and already authenticated.
  for (const warm of cfg.prewarmUrls || []) {
    log("prewarming:", warm);
    try {
      await page.goto(warm, { waitUntil: "domcontentloaded", timeout: 45000 });
      for (let i = 0; i < 30 && page.url().includes("sign-in"); i++) await sleep(500);
      log("  settled at:", page.url());
    } catch (e) { log("  prewarm failed (continuing):", e.message); }
  }

  log("navigating:", cfg.url);
  await page.goto(cfg.url, { waitUntil: "domcontentloaded", timeout: 45000 });
  await page.bringToFront();
  await sleep(1800);

  // Full screen when asked. Cropping to the browser rectangle frames a slice of whatever desktop is
  // behind it, which reads as an accident; full screen also keeps the menu bar and tab strip in
  // shot, which matters when the demo switches between two tabs.
  openURL(cfg.fullScreen
    ? "demotape://record/start?countdown=0"
    : `demotape://record/start?mode=area&x=${Math.round(x)}&y=${Math.round(y)}&w=${Math.round(width)}&h=${Math.round(height)}&countdown=0`);
  await waitForState("recording");
  const recordStart = Date.now();

  const clips = [];
  const verifyScenes = [];   // {at, say} where `at` is each scene's settled moment (for the vision check)
  const assertions = [];
  let aborted = false;
  for (const [idx, sc] of scenes.entries()) {
    const at = (Date.now() - recordStart) / 1000;
    const dur = sc.dur || 0.6;
    if (sc.clip) clips.push({ audio: sc.clip, at, say: sc.say || "" });
    const steps = sc.steps || [];
    const hasAction = steps.some((s) => !["wait", "narrate"].includes(s.action));
    log(`scene ${idx} @ ${at.toFixed(1)}s (line ${dur.toFixed(1)}s${hasAction ? ", action" : ""})`);

    // REVEAL actions (navigate / scroll / expand) run NOW so the viewer sees what the line is about
    // WHILE it's spoken (fixes "the page appears after the narration"). COMMIT actions (click/fill)
    // are the announced interactions — they lead with the line and trigger DemoTape's auto-zoom
    // when osClick is on, directing attention to the thing being described.
    const REVEAL = new Set(["goto", "expand", "waitFor", "hover", "scroll"]);
    const COMMIT = new Set(["click", "fill", "type", "press"]);
    const lead = sc.leadFraction ?? cfg.actionLeadFraction;
    const hasCommit = steps.some((s) => COMMIT.has(s.action));
    for (const step of steps) if (REVEAL.has(step.action)) {
      log("  reveal:", step.action, step.selector || step.url || step.y || "");
      try { await runStep(page, step, cfg); } catch (e) { log("  step failed:", e.message); }
    }
    if (hasCommit) await sleep(Math.max(0, dur * 1000 * lead));
    for (const step of steps) if (COMMIT.has(step.action)) {
      log("  commit:", step.action, step.selector || step.text || "");
      try { await runStep(page, step, cfg); } catch (e) { log("  step failed:", e.message); }
    }
    if (hasCommit) { try { await page.waitForLoadState("load", { timeout: 15000 }); } catch {} }

    if (sc.expect) {
      const r = await checkExpect(page, sc.expect);
      assertions.push({ scene: idx, ...r });
      log(`  assert scene ${idx}: ${r.ok ? "PASS" : "FAIL — " + r.reason}`);
      if (!r.ok) { aborted = true; break; }   // fail fast: don't record the rest of a broken take
    }
    // Attention gestures fill the rest of the spoken line: the cursor traces the regions being
    // described (point + optional emphasis click → auto-zoom), instead of sitting still. This is
    // the "game of attention with the mouse" — a few unhurried points that keep the eye moving.
    const rem = (at + dur + 0.35) - (Date.now() - recordStart) / 1000;
    if (sc.gestures && sc.gestures.length) {
      log(`  gestures: ${sc.gestures.length} across ${Math.max(0, rem).toFixed(1)}s`);
      await playGestures(page, cfg, sc.gestures, Math.max(0, rem) * 1000);
    } else if (rem > 0) {
      await sleep(rem * 1000);
    }
    // The scene's settled state is on screen now (end of scene) — photograph here for verification.
    verifyScenes.push({ at: Math.max(at, (Date.now() - recordStart) / 1000 - 0.5), say: sc.say || "" });
  }

  if (!aborted) await sleep(cfg.tailMs);   // tail so the final line is never clipped
  openURL("demotape://record/stop");
  // A persistent profile has no separate browser handle — close the context so the profile flushes.
  await (browser ? browser.close() : context.close());
  const done = await waitForState("idle", 15 * 60 * 1000);
  const styled = done.lastOutput;
  if (!styled) throw new Error("no output path reported by DemoTape");

  if (aborted) {   // an assertion failed — skip voiceover/verify and let the caller retry fast
    return { styled, finalPath: styled, assertions, assertionsOk: false, verify: null, verifyOk: false, ok: false };
  }
  log("rendered:", styled);

  // Lay each scene's line at its recorded offset.
  let finalPath = styled;
  if (clips.length) {
    const spec = join(tmpdir(), `dt-timeline-${Date.now()}.json`);
    writeFileSync(spec, JSON.stringify({ clips }), "utf8");
    try {
      const out = execFileSync(cfg.demotapeBin, ["--voiceover-timeline", styled, spec], { encoding: "utf8" });
      const m = out.match(/voiceover:\s*(.+)/);
      if (m) finalPath = m[1].trim();
    } catch (e) { log("voiceover-timeline failed (keeping styled):", e.message); }
    // Persist the timeline so the voice can be swapped later without re-recording (revoice mode).
    try {
      writeFileSync(join(dirname(styled), "timeline.json"),
        JSON.stringify({ voiceId: cfg.voiceId || "", styled, scenes: clips.map((c) => ({ at: c.at, say: c.say })) }, null, 2));
    } catch {}
  }

  // Verify the render semantically (vision model checks each scene's frame vs its line).
  let verify = null;
  let verifyUnavailable = null;   // set when the gate could not run at all (e.g. a 429)
  if (cfg.verify) {
    // Keep the spec BESIDE the recording, not just in a temp file. When the gate can't run (a rate
    // limit), the honest advice is "re-run just the gate later" — which is useless if the moments it
    // photographs are gone. These are the SETTLED moments (near the end of each scene, after its
    // action resolved), not the scene starts in timeline.json: judging a "now I'll type this" line
    // against the frame from before it was typed fails a take that was fine.
    const vspec = join(dirname(styled), "verify-scenes.json");
    try {
      writeFileSync(vspec, JSON.stringify({ scenes: verifyScenes }, null, 2), "utf8");
    } catch {
      writeFileSync(join(tmpdir(), `dt-verify-${Date.now()}.json`), JSON.stringify({ scenes: verifyScenes }), "utf8");
    }
    try {
      const out = execFileSync(cfg.demotapeBin, ["--verify", finalPath, vspec], { encoding: "utf8" });
      verify = JSON.parse(out);
    } catch (e) {
      // Exit code 2 = verification failed but produced a report on stdout.
      const out = e.stdout?.toString?.() || "";
      try { verify = JSON.parse(out); }
      catch {
        // No report at all: the gate couldn't RUN. That is not the same as the demo being wrong, and
        // reporting it as a failure sends people hunting for a bug in a take that was fine. The most
        // common cause is the provider rate-limiting the per-scene vision calls.
        const why = `${e.stderr?.toString?.() || ""}${e.message || ""}`;
        verifyUnavailable = /429|rate limit/i.test(why)
          ? "provider rate limit (429) — the take is unjudged, not failed"
          : (why.split("\n")[0] || "verification could not run");
        log("verify UNAVAILABLE:", verifyUnavailable);
        log(`  re-run the gate alone with: ${cfg.demotapeBin} --verify "${finalPath}" "${vspec}"`);
      }
    }
    if (verify) for (const s of verify.scenes) log(`  verify @${s.at.toFixed(1)}s: ${s.verdict.toUpperCase()} — ${s.reason}`);
  }

  const assertionsOk = assertions.every((a) => a.ok);
  // Three distinct outcomes, not two: verified, contradicted, and unjudged.
  const verifyOk = !cfg.verify || (verify && verify.pass);
  return { styled, finalPath, assertions, assertionsOk, verify, verifyOk,
           verifyUnavailable, ok: assertionsOk && verifyOk };
}

// Swap the voice on an already-recorded, scene-synced demo — no re-recording. Reuses the saved
// timeline.json (scene offsets + lines) and re-lays freshly synthesized clips onto the silent
// styled video, preserving sync.  Usage:  node driver.mjs revoice <folder-or-styled.mp4> <voiceId>
async function revoice(pathArg, voiceId) {
  const bin = resolve(__dirname, "..", "..", ".build", "release", "DemoTape");
  if (!pathArg || !voiceId) { log("usage: node driver.mjs revoice <recording-folder-or-styled.mp4> <voiceId>"); process.exit(1); }
  const p = resolve(pathArg);
  let styled, dir;
  if (statSync(p).isDirectory()) { dir = p; styled = readdirSync(p).map((f) => join(p, f)).find((f) => f.endsWith(".styled.mp4")); }
  else { styled = p; dir = dirname(p); }
  if (!styled || !existsSync(styled)) { log("no styled .mp4 found at", pathArg); process.exit(1); }
  const tlPath = join(dir, "timeline.json");
  if (!existsSync(tlPath)) { log("no timeline.json beside the video — this demo predates timeline saving; re-run the driver instead."); process.exit(1); }
  const tl = JSON.parse(readFileSync(tlPath, "utf8"));
  log(`revoicing ${tl.scenes.length} scene(s) with voice ${voiceId}`);
  const clips = [];
  for (const [i, sc] of tl.scenes.entries()) {
    const say = (sc.say || "").trim(); if (!say) continue;
    const nf = join(tmpdir(), `dt-rv-${i}-${Date.now()}.txt`); writeFileSync(nf, say, "utf8");
    const mp3 = join(tmpdir(), `dt-rv-${i}-${Date.now()}.mp3`);
    try { execFileSync(bin, ["--tts", nf, mp3, voiceId], { stdio: "ignore" }); clips.push({ audio: mp3, at: sc.at }); }
    catch (e) { log(`scene ${i} tts failed:`, e.message); }
  }
  const spec = join(tmpdir(), `dt-rv-spec-${Date.now()}.json`); writeFileSync(spec, JSON.stringify({ clips }), "utf8");
  const out = execFileSync(bin, ["--voiceover-timeline", styled, spec], { encoding: "utf8" });
  const m = out.match(/voiceover:\s*(.+)/); const final = m ? m[1].trim() : styled;
  try { const t = JSON.parse(readFileSync(tlPath, "utf8")); t.voiceId = voiceId; writeFileSync(tlPath, JSON.stringify(t, null, 2)); } catch {}
  log("revoiced ->", final);
  execFile("/usr/bin/open", [final]);
}

// Prepare an authenticated browser profile for demos of apps behind a login.
//   node driver.mjs signin <url> --profile <dir> [--email … --password …]
//
// Why this is a first-class command: recording an authenticated app means the session must already
// exist, because typing credentials on camera is both ugly and unsafe, and hosted login pages
// (Clerk, Auth0, Okta) are miserable to automate mid-take. Sign in once here, then point a demo
// config at the same `userDataDir` and the take opens straight into the app. Sessions expire, so
// re-run this when a prewarm lands on a sign-in page.
async function signin(url) {
  const arg = (name, fallback = "") => {
    const i = process.argv.indexOf(`--${name}`);
    return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
  };
  const profile = resolve(arg("profile", "tools/demo-driver/.profiles/default"));
  const email = arg("email", process.env.DEMO_EMAIL);
  const password = arg("password", process.env.DEMO_PASSWORD);
  if (!url) { log("usage: node driver.mjs signin <url> --profile <dir> [--email … --password …]"); process.exit(1); }

  log("profile:", profile);
  const ctx = await chromium.launchPersistentContext(profile, {
    headless: false, viewport: null,
    args: ["--window-position=60,60", "--window-size=1340,860", "--no-first-run", "--no-default-browser-check"],
  });
  const page = ctx.pages()[0] || await ctx.newPage();
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
  await sleep(2500);
  log("landed:", page.url());

  const target = new URL(url).pathname;
  const arrived = () => page.url().includes(target) && !/sign-?in|login/i.test(page.url());

  if (!arrived() && email && password) {
    // Two-step (identifier, then password) is the common hosted-login shape; a single-page form
    // works too because the password field is simply already present.
    const id = page.locator("input[name=identifier], input[type=email], input[name=email]").first();
    if (await id.count()) { await id.fill(email); await page.keyboard.press("Enter"); await sleep(3000); }
    const pw = page.locator("input[type=password], input[name=password]").first();
    await pw.waitFor({ timeout: 25000 });
    await pw.fill(password);
    await page.keyboard.press("Enter");
    for (let i = 0; i < 60 && !arrived(); i++) await sleep(1000);
  } else if (!arrived()) {
    log("no credentials given — sign in manually in the open window (waiting up to 3 min)…");
    for (let i = 0; i < 180 && !arrived(); i++) await sleep(1000);
  }

  log(arrived() ? `SIGNED IN — ${page.url()}` : `NOT SIGNED IN — ${page.url()}`);
  await ctx.close();                       // closing flushes cookies to the profile
  if (!arrived()) process.exit(1);
}

// Rehearse a config headlessly: run every step and assertion with NO recording, no cursor, no
// narration. This is step 5 of the skill's pipeline, and it exists because a bad selector or a
// changed flow should cost seconds, not a whole take plus a paid TTS pass. Exits non-zero if any
// scene's assertion fails, so it can gate a recording.
//   node driver.mjs <config> --rehearse
async function rehearse(cfg) {
  log("REHEARSAL (headless, no recording) —", cfg.scenes.length, "scene(s)");
  const args = ["--no-first-run", "--no-default-browser-check"];
  let browser = null, context, page;
  if (cfg.userDataDir) {
    context = await chromium.launchPersistentContext(cfg.userDataDir, { headless: true, args });
    page = context.pages()[0] || await context.newPage();
  } else {
    browser = await chromium.launch({ headless: true, args });
    context = await browser.newContext();
    page = await context.newPage();
  }
  // No recording means no cursor theatre and no OS input. osType MUST be off here: real keystrokes
  // go to whatever window is focused on the real desktop, which during a headless rehearsal is
  // whatever the operator happens to be using.
  cfg = { ...cfg, showCursor: false, osClick: false, osType: false, typeMs: 0 };

  await page.goto(cfg.url, { waitUntil: "domcontentloaded", timeout: 45000 });
  let failures = 0;
  for (const [i, sc] of cfg.scenes.entries()) {
    for (const step of sc.steps || []) {
      try { await runStep(page, step, cfg); }
      catch (e) {
        failures++;
        log(`scene ${i}: STEP FAILED (${step.action} ${step.selector || step.url || ""}) — ${(e.message || "").split("\n")[0]}`);
      }
    }
    if (sc.expect) {
      const r = await checkExpect(page, sc.expect);
      if (!r.ok) failures++;
      log(`scene ${i}: assert ${r.ok ? "PASS" : "FAIL — " + r.reason}`);
    } else {
      log(`scene ${i}: ok (no assertion)`);
    }
  }
  await (browser ? browser.close() : context.close());
  log(failures ? `REHEARSAL FAILED (${failures} problem(s)) — fix before recording` : "REHEARSAL PASSED — safe to record");
  if (failures) process.exit(1);
}

async function main() {
  if (process.argv[2] === "revoice") { await revoice(process.argv[3], process.argv[4]); return; }
  if (process.argv[2] === "signin") { await signin(process.argv[3]); return; }
  const { cfg, path } = loadConfig();
  log("config:", path, "·", cfg.scenes.length, "scene(s)");

  // Rehearse before the expensive parts: no recording, no TTS, no vision check.
  if (process.argv.includes("--rehearse")) { await rehearse(cfg); return; }

  // Synthesize each scene's line once (reused across retry attempts).
  if (existsSync(cfg.demotapeBin)) {
    let synthFailures = 0;
    for (const [idx, sc] of cfg.scenes.entries()) {
      const say = (sc.say || "").trim();
      if (!say) continue;
      const nf = join(tmpdir(), `dt-scene-${idx}-${Date.now()}.txt`);
      writeFileSync(nf, say, "utf8");
      const mp3 = join(tmpdir(), `dt-scene-${idx}-${Date.now()}.mp3`);
      const ttsArgs = ["--tts", nf, mp3]; if (cfg.voiceId) ttsArgs.push(cfg.voiceId);
      try {
        // Capture stderr so the real API reason (e.g. ElevenLabs quota) is visible, not hidden.
        execFileSync(cfg.demotapeBin, ttsArgs, { stdio: ["ignore", "ignore", "pipe"] });
        sc.clip = mp3; sc.dur = measureDuration(mp3); log(`scene ${idx}: ${sc.dur.toFixed(1)}s`);
      } catch (e) {
        const detail = ((e.stderr || "") + (e.message || "")).trim();
        log(`scene ${idx} tts failed: ${detail.split("\n")[0]}`);
        synthFailures++;
        // Out of ElevenLabs credits: no later scene will succeed either. Stop now with a clear,
        // actionable message instead of producing a half-narrated take that burns the last credits.
        if (/quota_exceeded|quota of|credits remaining|insufficient/i.test(detail)) {
          const m = detail.match(/You have\s+\d+\s+credits remaining[^.]*\./i);
          log("ABORT: ElevenLabs quota exhausted" + (m ? ` — ${m[0]}` : "") +
              " Top up credits (elevenlabs.io) or set a different DEMOTAPE_ELEVEN_KEY, then re-run.");
          console.error("\nElevenLabs is out of credits — cannot narrate this demo." +
                        (m ? `\n${m[0]}` : "") +
                        "\nAdd credits or switch keys, then re-run. Nothing was recorded.\n");
          process.exit(2);
        }
      }
    }
    if (synthFailures && synthFailures === cfg.scenes.filter((s) => (s.say || "").trim()).length) {
      log("ABORT: every scene failed to synthesize — check the ElevenLabs key/network.");
      console.error("\nNo narration could be synthesized (all scenes failed). Check DEMOTAPE_ELEVEN_KEY and network.\n");
      process.exit(2);
    }
  }

  let result = null;
  for (let attempt = 1; attempt <= cfg.maxAttempts; attempt++) {
    log(`=== attempt ${attempt}/${cfg.maxAttempts} ===`);
    try { result = await runOnce(cfg, cfg.scenes); }
    catch (e) { log("attempt error:", e.message); continue; }
    if (result.ok) { log("PASS — output matches the script"); break; }
    // An unjudged run is not a failed one. Retrying a take because the provider rate-limited the
    // vision gate wastes minutes and a paid re-synthesis, and can't fix anything.
    if (result.assertionsOk && result.verifyUnavailable) {
      log(`INCONCLUSIVE — every assertion passed, but the vision gate could not run: ${result.verifyUnavailable}`);
      log("Review the video by hand, or re-run just the gate later.");
      break;
    }
    log(`FAIL — assertions:${result.assertionsOk} verify:${result.verifyOk}${attempt < cfg.maxAttempts ? " — retrying" : ""}`);
  }

  if (!result) { log("no result produced"); process.exit(1); }

  // Write a verification report next to the video (the "test report").
  const report = {
    ok: result.ok, assertionsOk: result.assertionsOk, verifyOk: result.verifyOk,
    // Recorded explicitly so a reader can tell "the gate said no" from "the gate never ran".
    verifyUnavailable: result.verifyUnavailable ?? null,
    assertions: result.assertions, verify: result.verify, video: result.finalPath,
  };
  const reportPath = join(dirname(result.finalPath), "demo-report.json");
  try { writeFileSync(reportPath, JSON.stringify(report, null, 2)); log("report:", reportPath); } catch {}

  const label = result.ok ? "final (verified):"
    : result.assertionsOk && result.verifyUnavailable ? "final (assertions passed, gate unjudged — review):"
    : "final (UNVERIFIED — review):";
  log(label, result.finalPath);
  execFile("/usr/bin/open", [result.finalPath]);
  // Exit 3 for "unjudged" so a script can tell it apart from a genuine mismatch (2).
  process.exit(result.ok ? 0 : (result.assertionsOk && result.verifyUnavailable ? 3 : 2));
}

main().catch((e) => { log("fatal:", e?.message || String(e)); process.exit(1); });
