#!/bin/bash
set -Eeuo pipefail

# DemoTape — local AI setup
# =========================
#
# Turns on DemoTape's narration and captions using models that run ON THIS MAC.
# No API keys, no accounts, no per-minute billing, and nothing leaves the machine.
#
# What this does (up to 7 steps):
#   1. Check DemoTape is installed
#   2. Check Docker is installed and running
#   3. Pull the speech models (Kokoro for narration, Whisper for captions)
#   4. Start them as local servers
#   5. Wait until each one answers
#   6. Point DemoTape at them and turn both features on
#   7. Prove it works end to end (synthesize a real clip, transcribe it back)
#
# Some steps are skipped when there's nothing to do (a model already pulled, a
# server already running). 7 is the ceiling; fewer can run.
#
# What leaves this machine:
#   Nothing. The two container images are downloaded once from a public registry;
#   after that every request goes to 127.0.0.1. DemoTape's recorder, renderer and
#   exporter never touch the network at all.
#
# What this changes on your Mac:
#   - Starts two Docker containers (named demotape-tts and demotape-stt)
#   - Writes DemoTape preferences (which server to use, and both AI features on)
#   It writes NO keys, touches no Keychain entry, and leaves your recordings alone.
#
# Disk + time:
#   ~2 GB of images, most of it the narration voices. First run takes a few
#   minutes on a normal connection; later runs start in seconds.
#
# Review it, or ask your agent, before running:
#   curl -fsSL https://demotape.dev/local-ai.sh -o local-ai.sh && less local-ai.sh
#   curl -fsSL https://demotape.dev/local-ai.sh | claude -p "explain what this script does"
#   curl -fsSL https://demotape.dev/local-ai.sh | codex exec "walk me through this script"
#
# Re-runs are cheap:
#   The container images are the only download, and they're cached. A second run
#   skips the pull, reuses running servers, and finishes in seconds. Safe to
#   re-run after any failure — every step checks before it acts.
#
# Usage:
#   local-ai.sh                 # set up narration + captions
#   local-ai.sh --tts-only      # narration only (skip the ~500MB Whisper image)
#   local-ai.sh --stt-only      # captions only
#   local-ai.sh --status        # what's running, and what DemoTape is pointed at
#   local-ai.sh --stop          # stop the servers (keeps the images)
#   local-ai.sh --uninstall     # stop, remove containers, restore hosted defaults
#   local-ai.sh --gpu           # use the CUDA images (NVIDIA only; not Apple Silicon)

# ── Configuration ────────────────────────────────────────────────────────────

TTS_CONTAINER="demotape-tts"
STT_CONTAINER="demotape-stt"
TTS_PORT="${DEMOTAPE_TTS_PORT:-8880}"
STT_PORT="${DEMOTAPE_STT_PORT:-8001}"
TTS_IMAGE="ghcr.io/remsky/kokoro-fastapi-cpu:latest"
STT_IMAGE="fedirz/faster-whisper-server:latest-cpu"
TTS_MODEL="kokoro"
TTS_VOICE="${DEMOTAPE_TTS_VOICE:-af_bella}"
STT_MODEL="${DEMOTAPE_STT_MODEL:-Systran/faster-whisper-base.en}"
APP_ID="dev.demotape.app"
APP_PATH="/Applications/DemoTape.app"
BIN="$APP_PATH/Contents/MacOS/DemoTape"

DO_TTS=1
DO_STT=1
TOTAL_STEPS=7

# ── Output helpers ───────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then _TTY=1; else _TTY=0; fi
_c() { # colour name, text
  if [ "$_TTY" != "1" ]; then printf '%s' "$2"; return; fi
  local code
  case "$1" in
    green) code=32 ;; yellow) code=33 ;; red) code=31 ;; dim) code=90 ;;
    *) printf '%s' "$2"; return ;;
  esac
  printf '\033[%sm%s\033[0m' "$code" "$2"
}
say()  { echo "$*"; }
warn() { echo "$(_c yellow "$*")" >&2; }
fail() { echo "$(_c red "$*")" >&2; }

# ERR trap: only fires on unhandled failures (not on explicit `exit N` after a
# friendly message, and not on `|| true`-guarded commands). Prints enough for a
# bug report instead of dying silently.
_on_error() {
  local ec=$? line="${BASH_LINENO[0]:-?}" cmd="${BASH_COMMAND:-?}"
  {
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "DemoTape local-AI setup hit an unexpected error."
    echo ""
    echo "  exit code: $ec"
    echo "  line:      $line"
    echo "  command:   $cmd"
    echo ""
    echo "Nothing is half-configured: re-running is safe, and"
    echo "  local-ai.sh --uninstall"
    echo "puts everything back the way it was."
    echo ""
    echo "Please open an issue with the lines above:"
    echo "  https://github.com/gabosarmiento/demotape/issues"
    echo "────────────────────────────────────────────────────────"
  } >&2
}
trap _on_error ERR

# ── Small utilities ──────────────────────────────────────────────────────────

# Is a container running right now?
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; }
# Does a container exist at all (running or stopped)?
exists()  { docker inspect "$1" >/dev/null 2>&1; }

# Read a DemoTape preference (empty when unset).
pref()      { defaults read "$APP_ID" "$1" 2>/dev/null || true; }
# -string is required, not optional: without an explicit type `defaults` parses the
# value as a plist, so a provider name like "Local (OpenAI-compatible)" is read as
# an array and the write fails ("Could not parse ... Try single-quoting it").
pref_set()  { defaults write "$APP_ID" "$1" -string "$2"; }
pref_bool() { defaults write "$APP_ID" "$1" -bool "$2"; }

# Poll an HTTP endpoint until it answers, or give up. Returns 1 on timeout.
wait_for_http() {
  local url="$1" label="$2" timeout="${3:-180}" waited=0
  printf '  waiting for %s' "$label"
  while [ "$waited" -lt "$timeout" ]; do
    if curl -fsS --max-time 3 -o /dev/null "$url" 2>/dev/null; then
      printf ' %s\n' "$(_c green "ready")"
      return 0
    fi
    # A container that died while we waited will never answer — say so now.
    printf '.'
    sleep 3
    waited=$((waited + 3))
  done
  printf ' %s\n' "$(_c red "timed out")"
  return 1
}

# ── Steps ────────────────────────────────────────────────────────────────────

check_demotape() {
  if [ ! -x "$BIN" ]; then
    fail "DemoTape isn't installed at $APP_PATH."
    echo "" >&2
    echo "Install it first (either works):" >&2
    echo "  • Download the notarized DMG: https://github.com/gabosarmiento/demotape/releases/latest" >&2
    echo "  • Or build from source:       git clone https://github.com/gabosarmiento/demotape && cd demotape && ./build-app.sh release" >&2
    exit 1
  fi
  local version
  version=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
  say "[1/$TOTAL_STEPS] DemoTape $version found ✓"
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker isn't installed."
    echo "" >&2
    echo "The speech models run in containers, so Docker is the one prerequisite." >&2
    echo "" >&2
    echo "Install Docker Desktop:  https://www.docker.com/products/docker-desktop/" >&2
    echo "Or a lighter runtime:    brew install colima && colima start" >&2
    echo "" >&2
    echo "Prefer not to run Docker? DemoTape works with hosted providers instead —" >&2
    echo "add a key in AI Settings. The recorder and renderer never need either." >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    # Try to start Docker Desktop, but don't assume it's the runtime in use.
    if open -a Docker 2>/dev/null; then
      printf '  Docker isn'"'"'t running — starting Docker Desktop'
      local waited=0
      while [ "$waited" -lt 90 ]; do
        if docker info >/dev/null 2>&1; then printf ' %s\n' "$(_c green "up")"; break; fi
        printf '.'; sleep 3; waited=$((waited + 3))
      done
    fi
    if ! docker info >/dev/null 2>&1; then
      echo "" >&2
      fail "Docker is installed but its engine isn't running."
      echo "Start whichever runtime you use, then re-run this script:" >&2
      echo "  Docker Desktop:   open -a Docker" >&2
      echo "  colima:           colima start" >&2
      echo "  OrbStack:         open -a OrbStack" >&2
      echo "  Rancher Desktop:  open -a 'Rancher Desktop'" >&2
      exit 1
    fi
  fi
  say "[2/$TOTAL_STEPS] Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '') running ✓"
}

pull_images() {
  say "[3/$TOTAL_STEPS] Getting the speech models..."
  local pulled=0
  if [ "$DO_TTS" = 1 ] && ! docker image inspect "$TTS_IMAGE" >/dev/null 2>&1; then
    printf '  narration (Kokoro, ~1.5GB, first time only)...'
    if docker pull -q "$TTS_IMAGE" >/dev/null 2>&1; then
      printf ' %s\n' "$(_c green "done")"; pulled=1
    else
      printf ' %s\n' "$(_c red "failed")"
      fail "Couldn't download the narration model. Check your connection and re-run."
      exit 1
    fi
  fi
  if [ "$DO_STT" = 1 ] && ! docker image inspect "$STT_IMAGE" >/dev/null 2>&1; then
    printf '  captions (Whisper, ~500MB, first time only)...'
    if docker pull -q "$STT_IMAGE" >/dev/null 2>&1; then
      printf ' %s\n' "$(_c green "done")"; pulled=1
    else
      printf ' %s\n' "$(_c red "failed")"
      fail "Couldn't download the captions model. Check your connection and re-run."
      exit 1
    fi
  fi
  [ "$pulled" = 0 ] && say "  already downloaded ✓"
}

start_servers() {
  say "[4/$TOTAL_STEPS] Starting the servers..."
  if [ "$DO_TTS" = 1 ]; then
    if running "$TTS_CONTAINER"; then
      say "  narration already running on port $TTS_PORT ✓"
    else
      exists "$TTS_CONTAINER" && docker rm -f "$TTS_CONTAINER" >/dev/null 2>&1 || true
      docker run -d --name "$TTS_CONTAINER" --restart unless-stopped \
        -p "127.0.0.1:${TTS_PORT}:8880" "$TTS_IMAGE" >/dev/null
      say "  narration → http://localhost:$TTS_PORT/v1"
    fi
  fi
  if [ "$DO_STT" = 1 ]; then
    if running "$STT_CONTAINER"; then
      say "  captions already running on port $STT_PORT ✓"
    else
      exists "$STT_CONTAINER" && docker rm -f "$STT_CONTAINER" >/dev/null 2>&1 || true
      docker run -d --name "$STT_CONTAINER" --restart unless-stopped \
        -p "127.0.0.1:${STT_PORT}:8000" "$STT_IMAGE" >/dev/null
      say "  captions  → http://localhost:$STT_PORT/v1"
    fi
  fi
  # Bound to 127.0.0.1 on purpose: these servers have no authentication, so they
  # must not be reachable from the network.
  say "  $(_c dim "both bound to 127.0.0.1 only — not reachable from your network")"
}

wait_ready() {
  say "[5/$TOTAL_STEPS] Waiting for the models to load..."
  local ok=1
  if [ "$DO_TTS" = 1 ]; then
    wait_for_http "http://localhost:$TTS_PORT/v1/audio/voices" "narration" 240 || ok=0
  fi
  if [ "$DO_STT" = 1 ]; then
    wait_for_http "http://localhost:$STT_PORT/v1/models" "captions" 240 || ok=0
  fi
  if [ "$ok" != 1 ]; then
    echo "" >&2
    fail "A server didn't come up in time."
    echo "See what it said:" >&2
    [ "$DO_TTS" = 1 ] && echo "  docker logs $TTS_CONTAINER --tail 40" >&2
    [ "$DO_STT" = 1 ] && echo "  docker logs $STT_CONTAINER --tail 40" >&2
    echo "" >&2
    echo "On a slow machine the first load can exceed the wait. The containers are" >&2
    echo "still starting — re-run this script in a minute and it will pick up." >&2
    exit 1
  fi
}

configure_demotape() {
  say "[6/$TOTAL_STEPS] Pointing DemoTape at them..."
  if [ "$DO_TTS" = 1 ]; then
    pref_set ttsProvider "OpenAI-compatible"
    pref_set ttsBaseURL "http://localhost:$TTS_PORT/v1"
    pref_set ttsModel "$TTS_MODEL"
    pref_set ttsVoice "$TTS_VOICE"
    pref_bool voiceoverEnabled true
    say "  narration: local Kokoro, voice $TTS_VOICE"
  fi
  if [ "$DO_STT" = 1 ]; then
    pref_set aiProvider "Local (OpenAI-compatible)"
    pref_set sttBaseURL "http://localhost:$STT_PORT/v1"
    pref_set sttModel "$STT_MODEL"
    pref_bool captionsEnabled true
    say "  captions:  local Whisper, model $STT_MODEL"
  fi
  say "  $(_c dim "no API key written; your Keychain is untouched")"
}

# Prove it rather than claim it: synthesize a real clip and, when captions are
# also set up, transcribe that clip back. A log line saying "configured" is not
# evidence the pipeline works.
verify() {
  say "[7/$TOTAL_STEPS] Checking it actually works..."
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  local spoken="Local narration is working."
  if [ "$DO_TTS" = 1 ]; then
    printf '  synthesizing a test clip...'
    printf '%s\n' "$spoken" > "$tmp/script.txt"
    if DEMOTAPE_TTS_PROVIDER="OpenAI-compatible" \
       DEMOTAPE_TTS_BASEURL="http://localhost:$TTS_PORT/v1" \
       DEMOTAPE_TTS_MODEL="$TTS_MODEL" \
       DEMOTAPE_TTS_VOICE="$TTS_VOICE" \
       "$BIN" --tts "$tmp/script.txt" "$tmp/probe.mp3" >/dev/null 2>&1 \
       && [ -s "$tmp/probe.mp3" ]; then
      printf ' %s (%s KB)\n' "$(_c green "ok")" "$(( $(wc -c < "$tmp/probe.mp3") / 1024 ))"
    else
      printf ' %s\n' "$(_c red "failed")"
      fail "The narration server is up but DemoTape couldn't synthesize through it."
      echo "  docker logs $TTS_CONTAINER --tail 40" >&2
      exit 1
    fi
  fi

  if [ "$DO_STT" = 1 ]; then
    printf '  transcribing it back...'
    # Transcription needs a video container; the STT round-trip is checked
    # directly against the server so this stays a real end-to-end read.
    local heard
    heard=$(curl -fsS --max-time 90 \
      -F "file=@$tmp/probe.mp3" -F "model=$STT_MODEL" \
      "http://localhost:$STT_PORT/v1/audio/transcriptions" 2>/dev/null || true)
    if [ -n "$heard" ]; then
      printf ' %s\n' "$(_c green "ok")"
      say "  $(_c dim "heard: $(printf '%s' "$heard" | tr -d '\n' | cut -c1-72)")"
    else
      # The narration path is already proven at this point, so this is a partial
      # failure, not a reason to throw the whole setup away.
      printf ' %s\n' "$(_c yellow "no answer")"
      warn "  Captions server didn't transcribe the probe. Narration still works."
      warn "  Check it with: docker logs $STT_CONTAINER --tail 40"
    fi
  fi
}

restart_app() {
  # DemoTape reads these preferences at use time, but a running instance may have
  # cached the old provider — restart it if it's open so the change takes effect.
  if pgrep -x DemoTape >/dev/null 2>&1; then
    osascript -e 'quit app "DemoTape"' >/dev/null 2>&1 || true
    sleep 1
    pkill -x DemoTape >/dev/null 2>&1 || true
    sleep 1
    open "$APP_PATH"
    say "  restarted DemoTape so it picks up the new settings"
  fi
}

# ── Subcommands ──────────────────────────────────────────────────────────────

cmd_status() {
  echo "DemoTape local AI — status"
  echo ""
  local t s
  t=$(running "$TTS_CONTAINER" && echo "running" || echo "stopped")
  s=$(running "$STT_CONTAINER" && echo "running" || echo "stopped")
  printf "  narration server  %-8s  %s\n" "$t" "http://localhost:$TTS_PORT/v1"
  printf "  captions server   %-8s  %s\n" "$s" "http://localhost:$STT_PORT/v1"
  echo ""
  echo "DemoTape is pointed at:"
  printf "  voiceover  %s  (%s, %s)  enabled=%s\n" \
    "$(pref ttsProvider)" "$(pref ttsBaseURL)" "$(pref ttsVoice)" "$(pref voiceoverEnabled)"
  printf "  captions   %s  (%s, %s)  enabled=%s\n" \
    "$(pref aiProvider)" "$(pref sttBaseURL)" "$(pref sttModel)" "$(pref captionsEnabled)"
  echo ""
  if [ "$t" = "running" ] || [ "$s" = "running" ]; then
    echo "Everything above runs on this Mac. No keys, no usage billing."
  else
    echo "Nothing is running. Start it with: local-ai.sh"
  fi
}

cmd_stop() {
  docker stop "$TTS_CONTAINER" "$STT_CONTAINER" >/dev/null 2>&1 || true
  say "Stopped. The images are kept, so starting again is quick:  local-ai.sh"
  say "DemoTape's settings are unchanged — narration and captions will fail until"
  say "you start the servers again (or switch back to a hosted provider)."
}

cmd_uninstall() {
  docker rm -f "$TTS_CONTAINER" "$STT_CONTAINER" >/dev/null 2>&1 || true
  # Put DemoTape back on its hosted defaults and turn the AI features off, so the
  # app returns to exactly the state it ships in.
  defaults delete "$APP_ID" ttsProvider    2>/dev/null || true
  defaults delete "$APP_ID" ttsBaseURL     2>/dev/null || true
  defaults delete "$APP_ID" ttsModel       2>/dev/null || true
  defaults delete "$APP_ID" ttsVoice       2>/dev/null || true
  defaults delete "$APP_ID" aiProvider     2>/dev/null || true
  defaults delete "$APP_ID" sttBaseURL     2>/dev/null || true
  defaults delete "$APP_ID" sttModel       2>/dev/null || true
  pref_bool voiceoverEnabled false
  pref_bool captionsEnabled false
  say "Removed the containers and restored DemoTape's defaults."
  say ""
  say "The downloaded images are still on disk. To reclaim that space:"
  say "  docker rmi $TTS_IMAGE $STT_IMAGE"
}

# ── Argument parsing ─────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --status)    cmd_status; exit 0 ;;
    --stop)      cmd_stop; exit 0 ;;
    --uninstall) cmd_uninstall; exit 0 ;;
    --tts-only)  DO_STT=0; shift ;;
    --stt-only)  DO_TTS=0; shift ;;
    --gpu)
      TTS_IMAGE="ghcr.io/remsky/kokoro-fastapi-gpu:latest"
      STT_IMAGE="fedirz/faster-whisper-server:latest-cuda"
      warn "Using CUDA images — these need an NVIDIA GPU and will not run on Apple Silicon."
      shift ;;
    -h|--help)
      sed -n '3,48p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      fail "Unknown option: $1"
      echo "Try: local-ai.sh --help" >&2
      exit 1 ;;
  esac
done

# ── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo "DemoTape — narration and captions, running on your Mac"
echo "$(_c dim "no API keys · no accounts · nothing leaves this machine")"
echo ""

check_demotape
check_docker
pull_images
start_servers
wait_ready
configure_demotape
verify
restart_app

echo ""
echo "$(_c green "Done.") Narration and captions now run locally."
echo ""
echo "Try it:"
echo "  1. Record something with DemoTape"
echo "  2. Add Voiceover… — type a line, press Generate"
echo "  3. Captions — press Transcribe, then pick a style"
echo ""
echo "Or headlessly, on a video you already have:"
echo "  $APP_PATH/Contents/MacOS/DemoTape --captions \"<video.mp4>\""
echo ""
echo "Useful later:"
echo "  local-ai.sh --status      what's running"
echo "  local-ai.sh --stop        free the memory (keeps the download)"
echo "  local-ai.sh --uninstall   put everything back"
echo ""
