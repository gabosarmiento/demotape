#!/usr/bin/env bash
# Install the "record-verified-demo" skill into a coding agent so it can produce narrated,
# self-verifying screen demos with DemoTape hands-off.
#
# Usage:
#   ./install.sh                 # install for Claude Code (~/.claude/skills)
#   ./install.sh --kiro          # install into this repo's Kiro steering (.kiro/steering)
#   ./install.sh --dir <path>    # install into a custom skills directory
#   ./install.sh --print         # just print the SKILL.md path (for piping/inspection)
#
# The skill only carries the *instructions*; the driver it runs lives in this repo
# (tools/demo-driver/driver.mjs), so keep your DemoTape checkout around and run demos from it.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/record-verified-demo"
SKILL_NAME="record-verified-demo"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

if [[ ! -f "${SRC_DIR}/SKILL.md" ]]; then
  echo "error: can't find ${SRC_DIR}/SKILL.md" >&2
  exit 1
fi

mode="claude"
target=""
case "${1:-}" in
  --print) echo "${SRC_DIR}/SKILL.md"; exit 0 ;;
  --kiro)  mode="kiro" ;;
  --dir)   mode="dir"; target="${2:-}"; [[ -n "$target" ]] || { echo "error: --dir needs a path" >&2; exit 1; } ;;
  "")      mode="claude" ;;
  *)       echo "error: unknown option '$1'" >&2; exit 1 ;;
esac

case "$mode" in
  claude)
    dest="${HOME}/.claude/skills/${SKILL_NAME}"
    mkdir -p "$dest"
    cp -R "${SRC_DIR}/." "$dest/"
    echo "Installed skill → ${dest}"
    echo "Claude Code will discover it automatically. Ask it to \"record a verified demo\"."
    ;;
  kiro)
    # Kiro reads steering from .kiro/steering. Install the SKILL as an auto-included steering doc
    # so the agent picks it up in this workspace.
    dest="${REPO_ROOT}/.kiro/steering"
    mkdir -p "$dest"
    cp "${SRC_DIR}/SKILL.md" "${dest}/${SKILL_NAME}.md"
    cp -R "${SRC_DIR}/references" "${dest}/${SKILL_NAME}-references" 2>/dev/null || true
    echo "Installed skill → ${dest}/${SKILL_NAME}.md (+ references)"
    echo "Open this repo in Kiro and ask it to \"record a verified demo\"."
    ;;
  dir)
    dest="${target%/}/${SKILL_NAME}"
    mkdir -p "$dest"
    cp -R "${SRC_DIR}/." "$dest/"
    echo "Installed skill → ${dest}"
    ;;
esac
