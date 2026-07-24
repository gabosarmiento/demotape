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
  cfg.osClick = cfg.osClick === true;
  cfg.actionLeadFraction = cfg.actionLeadFraction ?? 0.7;
  cfg.tailMs = cfg.tailMs ?? 1600;   // extra recording after the last line so it's never clipped
  cfg.maxAttempts = cfg.maxAttempts ?? 2;
  cfg.verify = cfg.verify !== false;
  cfg.demotapeBin = cfg.demotapeBin
    ? resolve(cfg.demotapeBin)
    : resolve(__dirname, "..", "..", ".build", "release", "DemoTape");
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

function osCursor(cfg, action, x, y) {
  // Route through the RUNNING installed app (holds the Accessibility grant + is the recording
  // process) so synthetic clicks actually register and trigger auto-zoom. The standalone CLI
  // binary is a separate unsigned executable the user never granted, so its CGEventPost no-ops.
  const url = `demotape://cursor/${action}?x=${Math.round(x)}&y=${Math.round(y)}`;
  try { execFileSync("/usr/bin/open", [url]); }
  catch (e) { log("cursor failed:", e.message); }
}

async function elementScreenCenter(page, selector) {
  try {
    const el = page.locator(selector).first();
    await el.scrollIntoViewIfNeeded({ timeout: 5000 });
    const box = await el.boundingBox();
    if (!box) return null;
    const w = await page.evaluate(() => ({ sx: window.screenX, sy: window.screenY, oh: outerHeight, ih: innerHeight }));
    return { x: w.sx + box.x + box.width / 2, y: w.sy + (w.oh - w.ih) + box.y + box.height / 2 };
  } catch { return null; }
}

async function moveCursorToSelector(page, cfg, selector) {
  if (!cfg.showCursor || !selector) return null;
  const c = await elementScreenCenter(page, selector);
  if (c) { osCursor(cfg, "move", c.x, c.y); await sleep(250); }
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
      osCursor(cfg, "move", p.x, p.y);
      await sleep(Math.min(slice * 0.45, 400));   // let the glide land before any click
      if (g.click && cfg.osClick) osCursor(cfg, "click", p.x, p.y);
    }
    const rest = slice - Math.min(slice * 0.45, 400);
    if (rest > 0) await sleep(rest);
  }
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
    case "type":
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
  const browser = await chromium.launch({ headless: false, args });
  const context = await browser.newContext({ viewport: null });
  const page = await context.newPage();
  log("navigating:", cfg.url);
  await page.goto(cfg.url, { waitUntil: "domcontentloaded", timeout: 45000 });
  await page.bringToFront();
  await sleep(1800);

  openURL(`demotape://record/start?mode=area&x=${Math.round(x)}&y=${Math.round(y)}&w=${Math.round(width)}&h=${Math.round(height)}&countdown=0`);
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
  await browser.close();
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
  if (cfg.verify) {
    const vspec = join(tmpdir(), `dt-verify-${Date.now()}.json`);
    writeFileSync(vspec, JSON.stringify({ scenes: verifyScenes }), "utf8");
    try {
      const out = execFileSync(cfg.demotapeBin, ["--verify", finalPath, vspec], { encoding: "utf8" });
      verify = JSON.parse(out);
    } catch (e) {
      // Exit code 2 = verification failed but produced a report on stdout.
      const out = e.stdout?.toString?.() || "";
      try { verify = JSON.parse(out); } catch { log("verify unavailable:", e.message); }
    }
    if (verify) for (const s of verify.scenes) log(`  verify @${s.at.toFixed(1)}s: ${s.verdict.toUpperCase()} — ${s.reason}`);
  }

  const assertionsOk = assertions.every((a) => a.ok);
  const verifyOk = !cfg.verify || (verify && verify.pass);
  return { styled, finalPath, assertions, assertionsOk, verify, verifyOk, ok: assertionsOk && verifyOk };
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

async function main() {
  if (process.argv[2] === "revoice") { await revoice(process.argv[3], process.argv[4]); return; }
  const { cfg, path } = loadConfig();
  log("config:", path, "·", cfg.scenes.length, "scene(s)");

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
    log(`FAIL — assertions:${result.assertionsOk} verify:${result.verifyOk}${attempt < cfg.maxAttempts ? " — retrying" : ""}`);
  }

  if (!result) { log("no result produced"); process.exit(1); }

  // Write a verification report next to the video (the "test report").
  const report = {
    ok: result.ok, assertionsOk: result.assertionsOk, verifyOk: result.verifyOk,
    assertions: result.assertions, verify: result.verify, video: result.finalPath,
  };
  const reportPath = join(dirname(result.finalPath), "demo-report.json");
  try { writeFileSync(reportPath, JSON.stringify(report, null, 2)); log("report:", reportPath); } catch {}

  log(result.ok ? "final (verified):" : "final (UNVERIFIED — review):", result.finalPath);
  execFile("/usr/bin/open", [result.finalPath]);
  process.exit(result.ok ? 0 : 2);
}

main().catch((e) => { log("fatal:", e?.message || String(e)); process.exit(1); });
