#!/usr/bin/env bash
# capture-debug-console.sh — Capture Lutheran Radio DEBUG console output from the iOS Simulator.
#
# Location: Scripts/ (repo helper; not a product or CI gate).
# Primary use: cold-launch / streamplay / widget-path marker analysis after a Debug sim build.
#
# What this tool is good at:
#   Real Debug `print()` capture via `simctl launch --console-pty` + a Python PTY reader,
#   then optional acceptance greps. `log stream` alone does NOT include app DEBUG print output.
#
# What this tool is NOT:
#   UI automation, element clicking, or reliable automated widget switches.
#   For widget pause/play/switch paths, drive the Simulator yourself under --manual.
#   In-app chrome UI tests belong in XCUITest (with -UITestMode), not here.
#
# Usage (after a Debug simulator build):
#   ./Scripts/capture-debug-console.sh --short              # cold launch → initial-streamplay-start.txt
#   ./Scripts/capture-debug-console.sh --manual             # you drive the sim → manual-streamplay-session.log
#   ./Scripts/capture-debug-console.sh --analyze [logfile]  # acceptance greps (no Simulator)
#
# Manual session (recommended for widget / switch / pause churn):
#   ./Scripts/capture-debug-console.sh --manual
#   # In Simulator: cold launch → pause → resume → widget pause/play → widget switch ×3
#   # Stop with Ctrl+C (SIGINT) — the script flushes the log and runs --analyze.
#   # Or wait for CAPTURE_TIMEOUT_SEC (default 600s). Ctrl+X is not a stop signal.
#
# Environment overrides:
#   SIM_UDID            Simulator UDID (default: booted iPhone 17* → available iPhone 17*
#                       → any booted iPhone; see resolve_sim_udid)
#   APP_PATH            Lutheran Radio.app path (default: newest valid DerivedData Debug build)
#   OUTPUT_FILE         Output path (defaults per mode; also used by --analyze if no path arg)
#   PLAYBACK_WAIT_SEC   Extra seconds after first "applied playing" in --short (default: 15)
#   CAPTURE_TIMEOUT_SEC Max capture duration (default: 120 short / 600 manual)
#
# --short exit status: non-zero if required cold-launch markers are missing
#   (cold-launch first play ≥ 1 and LIVE ICY ≥ 1). --manual / --analyze are advisory counts only.
#
# Build prerequisite (adjust SDK/destination from `xcrun simctl list devices available`):
#   xcodebuild -scheme "Lutheran Radio" -sdk iphonesimulator \
#     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="radio.lutheran.Lutheran-Radio"
APP_GROUP="group.radio.lutheran.shared"

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

MODE=""
ANALYZE_PATH=""
case "${1:-}" in
  --short)   MODE="short" ;;
  --manual)  MODE="manual" ;;
  --analyze)
    MODE="analyze"
    ANALYZE_PATH="${2:-}"
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Usage: $0 --short | --manual | --analyze [logfile]" >&2
    echo "Run with --help for details." >&2
    exit 1
    ;;
esac

# Prefer ripgrep; fall back to grep -E. Always emit a bare integer (0 if no matches).
count_matches() {
  local pattern="$1"
  local file="$2"
  local n
  if command -v rg >/dev/null 2>&1; then
    n="$(rg -c "$pattern" "$file" 2>/dev/null || true)"
  else
    n="$(grep -Ec "$pattern" "$file" 2>/dev/null || true)"
  fi
  [[ -n "$n" ]] || n=0
  echo "$n"
}

# First UUID on a matching simctl "devices available" line.
# $1 = awk condition (without braces), e.g. '/iPhone 17/ && /Booted/'
_first_sim_udid_where() {
  local cond="$1"
  xcrun simctl list devices available 2>/dev/null \
    | awk -F '[()]' "$cond"' {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^[0-9A-Fa-f-]{36}$/) { print $i; exit }
        }
      }'
}

# Prefer iPhone 17* (Pro / Pro Max / Air / base), then any booted iPhone.
# Order: booted 17* → available 17* → any booted iPhone.
resolve_sim_udid() {
  if [[ -n "${SIM_UDID:-}" ]]; then
    echo "$SIM_UDID"
    return
  fi
  local udid
  udid="$(_first_sim_udid_where '/iPhone 17/ && /Booted/')"
  if [[ -z "$udid" ]]; then
    udid="$(_first_sim_udid_where '/iPhone 17/')"
  fi
  if [[ -z "$udid" ]]; then
    udid="$(_first_sim_udid_where '/iPhone / && /Booted/')"
  fi
  if [[ -z "$udid" ]]; then
    echo "ERROR: No suitable iPhone simulator found." >&2
    echo "  Prefer iPhone 17* (boot one, or leave any iPhone booted)." >&2
    echo "  Or set SIM_UDID from: xcrun simctl list devices available" >&2
    exit 1
  fi
  echo "$udid"
}

resolve_app_path() {
  if [[ -n "${APP_PATH:-}" ]]; then
    if [[ -d "$APP_PATH" ]] && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist" &>/dev/null; then
      echo "$APP_PATH"
      return
    fi
    echo "ERROR: APP_PATH is missing or has no bundle ID: $APP_PATH" >&2
    exit 1
  fi

  local candidate=""
  while IFS= read -r path; do
    if /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$path/Info.plist" &>/dev/null; then
      candidate="$path"
      break
    fi
  done < <(
    find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path "*/Build/Products/Debug-iphonesimulator/Lutheran Radio.app" \
      -not -path "*/Index.noindex/*" \
      -type d 2>/dev/null \
      | while read -r p; do
          echo "$(stat -f '%m' "$p" 2>/dev/null || echo 0) $p"
        done \
      | sort -rn \
      | awk '{ $1=""; sub(/^ /,""); print }'
  )

  if [[ -z "$candidate" ]]; then
    echo "ERROR: Lutheran Radio.app not found. Run xcodebuild build first or set APP_PATH." >&2
    exit 1
  fi
  echo "$candidate"
}

default_output_file() {
  case "$MODE" in
    short)  echo "$ROOT_DIR/initial-streamplay-start.txt" ;;
    manual) echo "$ROOT_DIR/manual-streamplay-session.log" ;;
    *)      echo "" ;;
  esac
}

resolve_analyze_path() {
  if [[ -n "$ANALYZE_PATH" ]]; then
    echo "$ANALYZE_PATH"
    return
  fi
  if [[ -n "${OUTPUT_FILE:-}" ]]; then
    echo "$OUTPUT_FILE"
    return
  fi
  # Prefer newest known capture among current defaults + legacy name.
  local candidates=(
    "$ROOT_DIR/manual-streamplay-session.log"
    "$ROOT_DIR/initial-streamplay-start.txt"
    "$ROOT_DIR/long-test-txt.log"
  )
  local f newest="" newest_m=0 m
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      m="$(stat -f '%m' "$f" 2>/dev/null || echo 0)"
      if (( m >= newest_m )); then
        newest_m=$m
        newest=$f
      fi
    fi
  done
  if [[ -n "$newest" ]]; then
    echo "$newest"
    return
  fi
  echo "ERROR: No log file to analyze. Pass a path: $0 --analyze path/to.log" >&2
  echo "  or set OUTPUT_FILE, or run --short / --manual first." >&2
  exit 1
}

# Print a label + match count. $1=display label, $2=regex, $3=file.
print_match() {
  printf "  %-55s %s\n" "$1" "$(count_matches "$2" "$3")"
}

# Patterns match production Debug print() substrings (Core/ + main app).
# Keep aligned with docs/cold-launch-streamplay-regression-checklist.md §12.
analyze_log() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    echo "ERROR: Log file not found: $log_file" >&2
    exit 1
  fi

  echo "Analyzing: $log_file"
  echo "Lines: $(wc -l < "$log_file" | tr -d ' ')"
  echo ""
  echo "=== Streamplay regression markers ==="
  echo "  Note: SecurityModelValidator 'started' only on DNS cache miss (1h); cache hits stay 0."
  print_match "[SecurityModelValidator] validateSecurityModel() started" \
    "\\[SecurityModelValidator\\] validateSecurityModel\\(\\) started" "$log_file"
  print_match "Initial validation completed" \
    "Initial validation completed" "$log_file"
  print_match "Stream model updated and secured AVPlayerItem prepared" \
    "Stream model updated and secured AVPlayerItem prepared" "$log_file"
  print_match "cold-launch first play, proceeding" \
    "cold-launch first play, proceeding" "$log_file"
  print_match "stream-switch play, proceeding" \
    "stream-switch play, proceeding" "$log_file"
  print_match "resume play, proceeding" \
    "resume play, proceeding" "$log_file"
  print_match "LIVE ICY" \
    "LIVE ICY" "$log_file"
  print_match "Widget switch: SharedPlayerManager.play() succeeded" \
    "Widget switch: SharedPlayerManager.play\\(\\) succeeded" "$log_file"

  echo ""
  echo "=== Widget-switch markers (expect from --manual sessions that switch streams) ==="
  echo "  Per successful switch: ~1× streamSwitch stop; 0× userAction stop; 0× Cleared userPaused"
  print_match "FORCE STOPPING … streamSwitch" \
    "FORCE STOPPING ALL PLAYBACK - reason: streamSwitch" "$log_file"
  print_match "FORCE STOPPING … userAction" \
    "FORCE STOPPING ALL PLAYBACK - reason: userAction" "$log_file"
  print_match "[Widget] Cleared userPaused lock" \
    "Cleared userPaused lock" "$log_file"
  print_match "setupPlaybackObservers()" \
    "setupPlaybackObservers\\(\\)" "$log_file"
  print_match "Executing widget switch action" \
    "Executing widget switch action" "$log_file"

  echo ""
  echo "=== Stream-failure → widget switch (0× blocked when failure path keeps shouldBePlaying) ==="
  print_match "[Widget Switch] Blocked — userPaused, no auto-resume" \
    "\\[Widget Switch\\] Blocked — userPaused, no auto-resume" "$log_file"
  print_match "playbackIntent: shouldBePlaying → userPaused (failure path)" \
    "playbackIntent: shouldBePlaying → userPaused" "$log_file"
  print_match "▶ [Widget Switch] Starting new stream" \
    "▶ \\[Widget Switch\\] Starting new stream" "$log_file"
  print_match "Widget switch: SharedPlayerManager.play() succeeded" \
    "Widget switch: SharedPlayerManager.play\\(\\) succeeded" "$log_file"
}

# --short only: hard fail if cold-launch never reached play + live ICY.
# --manual / --analyze remain count-only (sessions vary).
short_acceptance_gate() {
  local log_file="$1"
  local cold icy
  cold="$(count_matches "cold-launch first play, proceeding" "$log_file")"
  icy="$(count_matches "LIVE ICY" "$log_file")"

  echo ""
  echo "=== Short cold-launch acceptance (required) ==="
  printf "  %-55s %s (need ≥1)\n" "cold-launch first play, proceeding" "$cold"
  printf "  %-55s %s (need ≥1)\n" "LIVE ICY" "$icy"

  if (( cold < 1 || icy < 1 )); then
    echo "FAIL: --short requires cold-launch first play ≥ 1 and LIVE ICY ≥ 1." >&2
    return 1
  fi
  echo "PASS: required cold-launch markers present."
  return 0
}

run_capture() {
  local udid="$1"
  local app_path="$2"
  local output_file="$3"
  local raw_file="${output_file%.*}.raw"
  local playback_tail="${PLAYBACK_WAIT_SEC:-15}"
  local capture_timeout

  case "$MODE" in
    short)
      capture_timeout="${CAPTURE_TIMEOUT_SEC:-120}"
      ;;
    manual)
      capture_timeout="${CAPTURE_TIMEOUT_SEC:-600}"
      ;;
    *)
      echo "ERROR: run_capture called with unexpected mode: $MODE" >&2
      exit 1
      ;;
  esac

  echo "Simulator UDID: $udid"
  echo "App bundle:     $app_path"
  echo "Output file:    $output_file"
  echo "Mode:           $MODE"
  echo "Timeout:        ${capture_timeout}s"
  if [[ "$MODE" == "short" ]]; then
    echo "Playback tail:  ${playback_tail}s after first \"applied playing\""
    echo ""
    echo "Cold-launch capture: waits for applied playing + tail, then analyzes."
  else
    echo ""
    echo "Manual capture: drive the Simulator yourself, then Ctrl+C when done."
    echo "  (Ctrl+C = stop capture + write log + analyze. Ctrl+X does nothing.)"
    echo "Suggested flow: cold launch → pause → resume → widget pause/play → widget switch ×3"
    echo "This script only records console output; it does not tap UI or inject widget actions."
  fi
  echo ""

  xcrun simctl boot "$udid" 2>/dev/null || true
  open -a Simulator --args -CurrentDeviceUDID "$udid" 2>/dev/null || true
  xcrun simctl install "$udid" "$app_path"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true

  # Clear stale widget mailbox so a previous session cannot poison cold-launch logs.
  for key in pendingAction pendingActionId pendingActionTime pendingLanguage; do
    xcrun simctl spawn "$udid" defaults delete "$APP_GROUP" "$key" 2>/dev/null || true
  done

  # On interrupt we still want to sanitize .raw → output and analyze.
  # Only terminate the app + remove .raw after that finalize step.
  terminate_app() {
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  }
  remove_raw() {
    rm -f "$raw_file"
  }
  trap terminate_app INT TERM

  : > "$raw_file"

  # Python treats SIGINT as stop-capture (not crash): flush .raw, exit 0 so bash
  # can sanitize → OUTPUT_FILE and run acceptance greps. Ctrl+C is the documented
  # stop for --manual; Ctrl+X does nothing special in the terminal.
  set +e
  python3 - "$udid" "$BUNDLE_ID" "$raw_file" "$playback_tail" "$capture_timeout" "$MODE" <<'PY'
import select
import signal
import subprocess
import sys
import time

udid, bundle, raw_path, playback_tail_s, capture_timeout_s, mode = sys.argv[1:7]
playback_tail = float(playback_tail_s)
capture_timeout = float(capture_timeout_s)

stop_requested = False

def _request_stop(signum, frame):
    global stop_requested
    stop_requested = True

signal.signal(signal.SIGINT, _request_stop)
signal.signal(signal.SIGTERM, _request_stop)

subprocess.run(
    ["xcrun", "simctl", "terminate", udid, bundle],
    stderr=subprocess.DEVNULL,
    check=False,
)
proc = subprocess.Popen(
    ["xcrun", "simctl", "launch", "--console-pty", udid, bundle],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    bufsize=0,
)

buf = b""
playing_seen = False
playing_at = 0.0
start = time.time()

try:
    with open(raw_path, "wb") as f:
        while time.time() - start < capture_timeout and not stop_requested:
            r, _, _ = select.select([proc.stdout], [], [], 0.2)
            if r:
                chunk = proc.stdout.read(8192)
                if not chunk:
                    break
                f.write(chunk)
                f.flush()
                buf += chunk
                if not playing_seen and b"applied playing" in buf:
                    playing_seen = True
                    playing_at = time.time()

            # --short: stop after first real play + tail window.
            if (
                mode == "short"
                and playing_seen
                and playing_at
                and time.time() - playing_at >= playback_tail
            ):
                break
            # --manual: run until timeout, app exit, or Ctrl+C (SIGINT).
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

reason = "interrupted" if stop_requested else "complete"
print(
    f"capture: mode={mode} playing_seen={playing_seen} "
    f"elapsed={time.time() - start:.1f}s reason={reason}",
    file=sys.stderr,
)
# Always exit 0 so bash finalizes the log after Ctrl+C.
sys.exit(0)
PY
  set -e

  if [[ ! -s "$raw_file" ]]; then
    echo "ERROR: Capture produced no console output (empty raw file)." >&2
    echo "  Was the Debug build installed? Try rebuilding, then re-run." >&2
    terminate_app
    remove_raw
    exit 1
  fi

  python3 - "$raw_file" "$output_file" <<'PY'
import re
import sys

raw_path, out_path = sys.argv[1:3]
raw = open(raw_path, "rb").read().decode("utf-8", "replace")
lines = []
for line in raw.splitlines():
    clean = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]", "", line)
    if clean.strip():
        lines.append(clean)
with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + ("\n" if lines else ""))
print(f"Wrote {len(lines)} lines → {out_path}")
PY

  trap - INT TERM
  terminate_app
  remove_raw

  echo ""
  analyze_log "$output_file"
  if [[ "$MODE" == "short" ]]; then
    short_acceptance_gate "$output_file"
  fi
}

if [[ "$MODE" == "analyze" ]]; then
  analyze_log "$(resolve_analyze_path)"
  exit 0
fi

UDID="$(resolve_sim_udid)"
APP="$(resolve_app_path)"
OUT="${OUTPUT_FILE:-$(default_output_file)}"

run_capture "$UDID" "$APP" "$OUT"
