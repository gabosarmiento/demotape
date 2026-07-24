// Rehearsal: validate the full create-a-domain flow headlessly before recording.
import { chromium } from "playwright";
const b = await chromium.launch({ headless: true });
const p = await b.newPage();
const log = (...a) => console.log("[probe]", ...a);
const expand = (sel) => p.evaluate((s) => { const el = document.querySelector(s); const d = el && (el.tagName === "DETAILS" ? el : el.closest("details")); if (d) d.open = true; }, sel);
try {
  await p.goto("http://localhost:8081/sign-in", { waitUntil: "domcontentloaded" });
  await p.fill("input[name=subject]", "dev-user");
  await p.click("button[type=submit]");
  await p.waitForLoadState("load");
  log("signed in ->", p.url());

  await p.goto("http://localhost:8081/dashboard/build", { waitUntil: "domcontentloaded" });
  await p.waitForSelector("text=Paste one tool call", { timeout: 8000 });
  await expand("details.studio-af-replay");
  await p.fill("textarea[name=tool_call]", '{"tool":"refund.issue_refund","entity_type":"order","fields":{"order_id":"A-1001","amount":42.5}}');
  await p.click("button:has-text('Derive a control')");
  await p.waitForLoadState("load");
  await p.waitForSelector("summary:has-text('kiff.yaml')", { timeout: 8000 });
  log("derived control; yaml panel present");

  await expand("details.studio-handoff-manual");
  await expand("details.studio-yaml-panel");
  const yaml = "domain: refund-flow\nentity: Order\nevents: [ISSUE_REFUND]\nstates: [REQUESTED, REFUNDED]\ntransitions:\n  - on: ISSUE_REFUND\n    from: REQUESTED\n    to: REFUNDED\nactions:\n  - name: ISSUE_REFUND\n    allowed_states: [REQUESTED]\n    required_parameters: [amount_cents]\n    required_permissions: [refund-flow.issue_refund]\n    risk: high\n    approval: required\n    executor: cloud.proxy\npermissions:\n  roles:\n    tenant_owner: [refund-flow.issue_refund, refund-flow.issue_refund.approve]\n";
  await p.fill("textarea[name=yaml]", yaml);
  await p.click("button:has-text('Validate and activate')");
  await p.waitForLoadState("load");
  const onDomains = p.url().includes("/dashboard/domains");
  const present = (await p.locator("text=refund-flow").count()) > 0;
  log("activate ->", p.url(), "| refund-flow present:", present);
  log("REHEARSAL", (onDomains && present) ? "PASS ✅" : "FAIL ❌");
} catch (e) { log("REHEARSAL FAIL ❌:", e.message.split("\n")[0]); }
await b.close();
