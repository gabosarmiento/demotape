# Grounding a demo in the real app (anti-monkeypatch)

The failure mode this guards against: producing a demo that *looks* plausible but is fake —
narrating capabilities the app doesn't have, or typing inputs that a validator rejects (or that only
worked in a test fixture). Everything below is about getting **ground truth** from the code so the
demo is real.

## Use a code graph if present

If the repo has a graph (e.g. `graphify-out/` with `graph.json` + `GRAPH_REPORT.md`), use it to
orient fast: find the community/hub for the feature, the handlers and the data types involved. It's
faster than blind grepping for "where does creating an X actually happen and what does it require."
If there's no graph, grep the routes/handlers and the type definitions directly.

## Schema is truth, fixtures are not

To learn what a valid input looks like, read the **parser/validator struct**, not a test fixture:

- Find the type that the input unmarshals into (its field tags define the real shape and nesting).
- Find the validator and what it enforces (cross-references, allowed values, required fields).
- Find registries/enums the input must match (e.g. a set of allowed executor keys, event names).

Then, when the app rejects your input, **read the exact error and fix against the schema**. Real
example: a domain YAML was rejected twice —
1. "unmarshal errors" → the struct nested `roles` under `permissions:`, not at top level.
2. "unknown event ISSUE_REFUND" → a transition's `on:` must name a declared `event`.
Both fixes came from the struct + the validator message, not from guessing or copying a `*_test.go`
fixture (which used an older shape and would have kept failing).

Prove the corrected input works once (curl the endpoint, or a headless script) and note the success
signal before scripting the demo around it.

## Local-stack bring-up playbook

1. Read run instructions: Makefile (`run`, `dev`), `docker-compose.yml`, `.env.example`, README
   "local dev". Note default ports.
2. Prefer the lightest mode. Look for:
   - **Auth**: a `stub`/`dev` provider (`*_AUTH_PROVIDER=stub`) that avoids real SSO; sign-in is
     usually a plain form. Note any allow-list env (e.g. `*_STUB_SUBJECTS`) — use an allow-listed
     identity so downstream services accept the bearer.
   - **Persistence**: many services "fall back to in-memory when `*_DATABASE_URL` is unset" — great
     for a demo (and lets you reset state by restarting).
   - **Secrets**: session secrets may have a minimum length; cookies may default `Secure` — set the
     cookie non-Secure (`*_COOKIE_SECURE=false`) for plain-HTTP localhost so a real browser keeps
     the session.
3. Start each service as a background process (target the right dir without `cd`, e.g.
   `go -C <dir> run ./cmd/...`). Poll `/healthz` and confirm the demo page loads.
4. Authenticate the way the driver will: hit the sign-in form, submit a valid subject, confirm you
   land on an authenticated page.

## Progressive-disclosure UIs

Modern UIs hide secondary controls behind `<details>`, accordions, tabs, or "advanced" toggles. An
element can be present in the DOM but not visible, so a naive `fill`/`click` times out. Inspect the
rendered HTML for `<details class="…">`/`<summary>` wrapping your target, and expand it first
(the driver's `expand` action sets `open=true` idempotently) before interacting.

## Stateful demos

If the demo creates something that then persists (a record, a domain, a project), the app's UI
changes after creation (onboarding → "you already have one"). This breaks a second run and breaks
retries. Handle it by:
- Rehearsing, then **resetting state** (restart the in-memory backend) before the real recording.
- Setting `maxAttempts: 1` so a failure reports honestly instead of retrying into a changed UI.
