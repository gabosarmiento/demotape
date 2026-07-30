/**
 * Checks that the caret offset ADVANCES as text is typed, in every kind of field that matters.
 *
 * This exists because the failure it guards against was completely silent: on a `contenteditable`
 * composer, `el.value` is undefined, so the measured caret offset was zero for every keystroke. The
 * recording still succeeded, every assertion still passed, and the only symptom was that the camera
 * held on the left edge of the field while the sentence grew away to the right, unreadable. Nothing in
 * a log said so — which is exactly the kind of bug a test has to catch.
 *
 * Headless, no app, no network, no permissions:
 *   node test-caret.mjs
 */
import { chromium } from "playwright";
import { caretOffsetInElement } from "./caret.mjs";

const PAGE = `data:text/html,` + encodeURIComponent(`
<html><body style="font:16px -apple-system;padding:40px">
  <input id="input" style="width:600px;padding:14px 16px;font-size:16px">
  <textarea id="area" style="width:600px;height:90px;padding:14px 16px;font-size:16px"></textarea>
  <div id="editable" contenteditable="true"
       style="width:600px;padding:14px 16px;font-size:16px;border:1px solid #ccc"></div>
</body></html>`);

const SENTENCE = "the quick brown fox jumps over the lazy dog and keeps running";

let failures = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "  ok  " : "  FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
  if (!ok) failures++;
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
await page.goto(PAGE);

for (const sel of ["#input", "#area", "#editable"]) {
  await page.click(sel);
  const samples = [];
  for (const ch of SENTENceSafe(SENTENCE)) {
    await page.keyboard.type(ch);
    const off = await page.evaluate(caretOffsetInElement, sel);
    samples.push(off ? off.dx : null);
  }

  const nulls = samples.filter((s) => s === null).length;
  check(`${sel}: every sample measured`, nulls === 0, `${nulls} null(s)`);

  const first = samples[0], last = samples[samples.length - 1];
  check(`${sel}: caret advances`, last > first + 20,
        `first=${fmt(first)} last=${fmt(last)}`);

  // This is the exact regression: a constant offset means the caret never moved.
  const distinct = new Set(samples.map((s) => Math.round(s))).size;
  check(`${sel}: offset is not pinned`, distinct > 5, `${distinct} distinct value(s)`);

  // It should grow, not jump around (a wrap may step back, so allow decreases but not chaos).
  let regressions = 0;
  for (let i = 1; i < samples.length; i++) if (samples[i] < samples[i - 1] - 1) regressions++;
  check(`${sel}: growth is orderly`, regressions <= 3, `${regressions} backward step(s)`);
}

// A wrapping textarea must report a y offset on the second line, not stay on the first.
await page.click("#area");
await page.keyboard.press("Control+A");
await page.keyboard.type("line one");
const beforeWrap = await page.evaluate(caretOffsetInElement, "#area");
await page.keyboard.press("Enter");
await page.keyboard.type("line two");
const afterWrap = await page.evaluate(caretOffsetInElement, "#area");
check("#area: newline moves the caret down", afterWrap.dy > beforeWrap.dy,
      `dy ${fmt(beforeWrap.dy)} -> ${fmt(afterWrap.dy)}`);

// A missing element must be reported, not crash.
const gone = await page.evaluate(caretOffsetInElement, "#nope");
check("missing selector returns null", gone === null);

await browser.close();

function fmt(v) { return v === null ? "null" : Number(v).toFixed(1); }
function SENTENceSafe(s) { return Array.from(s); }

console.log(failures === 0 ? "\ncaret: all checks passed" : `\ncaret: ${failures} check(s) FAILED`);
process.exit(failures === 0 ? 0 : 1);
