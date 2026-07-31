# Security Policy

Thanks for helping keep DemoTape and its users safe.

DemoTape is a native macOS screen recorder that is **local by default**: the recorder, renderer,
and exporter make no network requests, there is no account or telemetry, and recordings stay on
your Mac. Network access happens only in explicitly opt-in AI features (captions, voiceover,
verification), which talk only to the endpoint you configure, and any API keys are stored in the
macOS Keychain. Please keep this in mind when assessing impact.

## Supported versions

Security fixes land on the latest release. Because DemoTape ships as source plus a convenience
build, "supported" means the newest tagged release and the current `main`.

| Version           | Supported          |
| ----------------- | ------------------ |
| Latest release (7.5.x) | ✅ |
| `main` (built from source) | ✅ |
| Older tagged releases  | ❌ (please update) |

## Reporting a vulnerability

**Please report security issues privately — do not open a public issue, pull request, or
discussion for a vulnerability.**

Use GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability** to open a private advisory visible only to you and the
   maintainers.

If private reporting is unavailable to you, open a regular issue that says only "I'd like to
report a security issue privately, please advise a contact" — with **no technical details** — and a
maintainer will follow up with a private channel.

### What to include

The more of this you can provide, the faster it can be triaged:

- A description of the issue and why you consider it a security concern.
- The DemoTape version (`DemoTape` menu → About, or the tag you built), and your macOS version.
- Clear steps to reproduce, ideally with a minimal example.
- The impact you believe it has (e.g. local data exposure, key disclosure, code execution).
- Any proof-of-concept, logs, or screenshots — with secrets redacted.

### What to expect

- **Acknowledgement:** within 3 business days.
- **Initial assessment:** within 7 business days, including whether we consider it in scope and a
  rough severity.
- **Fix and disclosure:** we aim to ship a fix promptly and will coordinate a disclosure timeline
  with you. We're happy to credit you in the release notes and advisory unless you prefer to remain
  anonymous.

Please give us a reasonable opportunity to address the issue before any public disclosure.

## Scope

In scope:

- The DemoTape application and its build/release scripts in this repository.
- The headless CLI hooks (`--render`, `--transcode`, `--captions`, `--burn`, `--publish`,
  `--voiceover`, `--verify`, etc.).
- The demo-driver tooling under `tools/`.
- Handling of secrets (API keys) and of the local recordings/exports the app writes.

Out of scope:

- Vulnerabilities in third-party AI providers or OpenAI-compatible endpoints you configure — report
  those to the respective provider.
- Issues that require a pre-compromised Mac, physical access, or a malicious local admin.
- The security of API keys you have pasted into a shell, a config file, or a public location
  yourself. Note the CLI reads keys from environment variables by design; protect those as you
  would any secret.
- Missing hardening that has no demonstrated impact (report as a normal enhancement issue).

## A note on the AI features

The opt-in AI steps send only what the step needs to the endpoint you configure — captions send the
audio, voiceover sends the script, verification sends the frames it judges. If you believe a step
transmits more than it should, or leaks a key, that is in scope and we'd like to hear about it.
