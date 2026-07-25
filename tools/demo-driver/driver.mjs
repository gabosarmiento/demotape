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
    const box = await el.boundingBox();
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
  if (c) {
    osCursor(cfg, "move", c.x, c.y, cfg.moveMs);
    // Wait out the glide, then a beat to aim — a human lands, settles, then presses.
    await sleep(cfg.moveMs + 160);
  }
  return c;
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
async function playGestures(page, cfg, gestures, windowMs) {
  if (!cfg.showCursor || !gestures || !gestures.length) { await sleep(Math.max(0, windowMs)); return; }
  const slice = Math.max(0, windowMs) / gestures.length;
  for (const g of gestures) {
    const p = await gesturePoint(page, cfg, g);
    if (p) {
      // Give the glide most of its slice so the travel is visible, but never longer than the
      // gesture's share of the spoken line.
      const travel = Math.min(cfg.moveMs, Math.max(220, slice * 0.5));
      osCursor(cfg, "move", p.x, p.y, travel);
      await sleep(Math.min(slice * 0.45, travel + 160));   // let the glide land before any click
      if (g.click && cfg.osClick) osCursor(cfg, "click", p.x, p.y);
    }
    const rest = slice - Math.min(slice * 0.45, 400);
    if (rest > 0) await sleep(rest);
  }
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
  if (cfg.osType && !step.browserType) {
    const cps = 1000 / base;
    const chars = text.length + punctuation * 4;    // pad so the hold covers the pauses too
    execFileSync("/usr/bin/open",
                 [`demotape://typing?chars=${chars}&cps=${cps.toFixed(1)}`]);
  }

  for (const ch of text) {
    await page.keyboard.type(ch);
    let d = base * (0.6 + Math.random() * 0.9);
    if (".?!".includes(ch)) d += base * 6;         // end of a thought
    else if (",;:—".includes(ch)) d += base * 3;   // a clause break
    else if (ch === " " && Math.random() < 0.08) d += base * 4;   // brief hesitation
    await sleep(d);
  }

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
      const c = await moveCursorToSelector(page, cfg, step.selector);
      if (cfg.osClick && c) osCursor(cfg, "click", c.x, c.y);
      else await page.click(step.selector, { timeout: step.timeout ?? 8000 });
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
    const vspec = join(tmpdir(), `dt-verify-${Date.now()}.json`);
    writeFileSync(vspec, JSON.stringify({ scenes: verifyScenes }), "utf8");
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
