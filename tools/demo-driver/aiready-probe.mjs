// Rehearsal for the AI-ready demo (headless, no recording).
import { chromium } from "playwright";
const b = await chromium.launch({ headless: true });
const p = await b.newPage();
const log = (...a) => console.log("[probe]", ...a);
let ok = true;
async function check(name, fn) { try { await fn(); log("PASS", name); } catch (e) { ok = false; log("FAIL", name, "-", e.message.split("\n")[0]); } }
try {
  await p.goto("http://localhost:8081/agent", { waitUntil: "domcontentloaded" });
  await check("agent: KIFF for agents", () => p.waitForSelector("text=KIFF for agents", { timeout: 6000 }));
  await check("agent: Interface", () => p.waitForSelector("text=Interface", { timeout: 6000 }));
  await check("agent: Machine surfaces", () => p.waitForSelector("text=Machine surfaces", { timeout: 6000 }));
  await p.goto("http://localhost:8081/llms.txt", { waitUntil: "domcontentloaded" });
  await check("llms.txt loads + mentions KIFF", async () => { if (!p.url().includes("/llms.txt")) throw new Error("url"); await p.waitForSelector("text=KIFF", { timeout: 6000 }); });
  await p.goto("http://localhost:8081/skills/kiff-domains.md", { waitUntil: "domcontentloaded" });
  await check("kiff-domains skill loads", async () => { if (!p.url().includes("kiff-domains")) throw new Error("url"); await p.waitForSelector("text=kiff-domains", { timeout: 6000 }); });
} catch (e) { ok = false; log("probe error:", e.message); }
await b.close();
log("REHEARSAL", ok ? "PASS ✅" : "FAIL ❌");
