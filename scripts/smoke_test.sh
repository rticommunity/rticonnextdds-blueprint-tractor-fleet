#!/bin/bash
# SPDX-FileCopyrightText: 2026 Real-Time Innovations, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# smoke_test.sh — End-to-end smoke test of the tractor fleet demo.
#
# Starts the full demo (stations, tractors, UI, and Persistence Service when
# demo_start.sh starts it) on a private domain tag with temporary persistence
# storage, exercises the main interactions through the dashboard, checks the
# results in the dashboard state and the application logs, then stops
# everything with demo_stop.sh. The Persistence Service check reports SKIP
# when the service isn't started (see DEMO_RUN_PERSISTENCE_SERVICE).
#
# Usage:
#   scripts/smoke_test.sh [--timeout SECONDS]
#
# Options:
#   --timeout S   Seconds to wait for all checks (default: 150)
#
# Requires the venv from setup.sourceme and a license (RTI_LICENSE_FILE, or
# $NDDSHOME/rti_license.dat). Refuses to run while demo processes are running. Exits
# non-zero if any check fails, and keeps the demo log for inspection.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="$REPO_DIR/venv/bin/python"

TIMEOUT=150
while (( $# > 0 )); do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '5,/^set /{ /^set /d; s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

if [[ ! -x "$PYTHON" ]]; then
    echo "ERROR: Python not found at $PYTHON. Run 'source setup.sourceme' first."
    exit 2
fi
if pgrep -f '[Pp]ython[0-9.]* .*(tractor_node|charging_station|fleet_ui)\.py' >/dev/null 2>&1; then
    echo "ERROR: Demo processes are already running. Stop them with scripts/demo_stop.sh."
    exit 2
fi

# Fleet configuration (TRACTORS, STATIONS, UI_PORT). Use a private domain tag
# so the test can't interfere with, or be disturbed by, another fleet.
export DOMAIN_TAG="smoke-test-$$"
source "$REPO_DIR/shared/fleet_common.sh"
UI_URL="http://localhost:$UI_PORT"
NUM_TRACTORS=${#TRACTORS[@]}
CMD_TRACTOR="${TRACTORS[0]}"
CHARGE_TRACTOR="${TRACTORS[1]}"

TMP_BASE="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMP_BASE%/}/fleet_smoke.XXXXXX")"
LOG="$WORK_DIR/demo.log"
STOP_LOG="$WORK_DIR/stop.log"
# Keep the user's persistent_data/ untouched.
export PERSISTENCE_STORAGE_DIR="$WORK_DIR/persistent_data"
# Python buffers stdout written to a file; the checks read the log as it grows.
export PYTHONUNBUFFERED=1
DEMO_PID=""

cleanup() {
    if [[ -n "$DEMO_PID" ]]; then
        "$SCRIPT_DIR/demo_stop.sh" > "$STOP_LOG" 2>&1
        kill "$DEMO_PID" 2>/dev/null
        wait "$DEMO_PID" 2>/dev/null
        DEMO_PID=""
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "Smoke test: ${NUM_TRACTORS} tractors, ${#STATIONS[@]} stations, timeout ${TIMEOUT}s"
echo "Domain tag: $DOMAIN_TAG"
echo "Demo log:   $LOG"

"$SCRIPT_DIR/demo_start.sh" all > "$LOG" 2>&1 &
DEMO_PID=$!
START=$(date +%s)

# ── Helpers ───────────────────────────────────────────────────────────────
elapsed() { echo $(( $(date +%s) - START )); }

# wait_until <command...>: retry every 2 s until it succeeds or the overall
# timeout expires. Prints the elapsed time on success.
wait_until() {
    while :; do
        if "$@" >/dev/null 2>&1; then
            elapsed
            return 0
        fi
        if (( $(elapsed) >= TIMEOUT )) || ! kill -0 "$DEMO_PID" 2>/dev/null; then
            return 1
        fi
        sleep 2
    done
}

in_log() { grep -q -E "$1" "$LOG"; }

# First /stream event, as JSON. grep -m1 closes the pipe early, so curl exits
# non-zero; ignore that (with pipefail it would fail the caller's pipeline).
# An empty or bad event still fails the JSON parse in stream_check.
stream_json() {
    curl -s -N -m 3 "$UI_URL/stream" 2>/dev/null | grep -m1 '^data: ' | sed 's/^data: //'
    return 0
}

# stream_check <python expression over d>: evaluate against the UI state.
stream_check() {
    stream_json | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"
}

# post_command <tractor> <command>: send through the UI; succeed if the
# tractor replied with success.
post_command() {
    curl -s -m 10 -X POST -H 'Content-Type: application/json' \
        -d "{\"tractor_id\": \"$1\", \"command\": \"$2\", \"goto_x\": 50, \"goto_y\": 50}" \
        "$UI_URL/command" | "$PYTHON" -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('success') else 1)"
}

video_frames() {
    curl -s -m 5 "$UI_URL/video_feed/$CMD_TRACTOR" -o "$WORK_DIR/video.mjpeg" 2>/dev/null
    [[ $(wc -c < "$WORK_DIR/video.mjpeg") -gt 2000 ]]
}

# ── Checks ────────────────────────────────────────────────────────────────
RESULTS=()
check() {  # name, command...
    local name="$1"; shift
    local t
    if t=$(wait_until "$@"); then
        RESULTS+=("PASS|$name|after ${t}s")
    else
        RESULTS+=("FAIL|$name|not seen within ${TIMEOUT}s")
    fi
    printf '  %s\n' "$name"
}

echo "Running checks..."
# demo_start.sh logs either that it starts the service or why it doesn't.
check "Persistence Service started"   in_log "Starting RTI Persistence Service|Persistence Service not started"
if [[ "${RESULTS[0]}" == PASS* ]] && ! in_log "Starting RTI Persistence Service"; then
    RESULTS[0]="SKIP|Persistence Service started|not started by demo_start.sh"
fi
check "Discovery + liveliness"        in_log "Tractor ALIVE \(alive=$NUM_TRACTORS\)"
check "Dashboard HTTP"                curl -s -f -o /dev/null "$UI_URL/"
check "OperationalState for all"      stream_check "len(d['operational']) == $NUM_TRACTORS"
check "StationStatus for all"         stream_check "len(d['charging']) == ${#STATIONS[@]}"
check "Command round-trip (GOTO)"     post_command "$CMD_TRACTOR" GOTO
check "Charge command accepted"       post_command "$CHARGE_TRACTOR" CHARGE
check "Charging slot reserved"        in_log "\[$CHARGE_TRACTOR [0-9:]+\] ⚡ Reserved slot"
check "Station granted the slot"      in_log "$CHARGE_TRACTOR (→ DOCKING|reserved slot)"
# One request with tractor_id "ALL" reaches every tractor; the dashboard
# reports success only if every known tractor replied.
check "Stop all (one request)"        post_command ALL STOP
check "Resume all (one request)"      post_command ALL RESUME
# Stop the charging tractor while it still holds its slot (it is usually
# still driving to the dock) and check that the rest of the system notices
# its departure through DDS alone.
"$SCRIPT_DIR/demo_stop.sh" tractor "$CHARGE_TRACTOR" > "$WORK_DIR/stop_tractor.log" 2>&1
check "Dashboard shows departure"     stream_check "d['presence'].get('$CHARGE_TRACTOR') == 'offline' or '$CHARGE_TRACTOR' not in d['state']"
check "Station freed departed slot"   in_log "$CHARGE_TRACTOR is gone — released slot"
check "Peers stopped avoiding it"     in_log "Peer $CHARGE_TRACTOR gone"
check "Coverage trail published"      stream_check "any(len(v) > 0 for v in d['coverage'].values())"
check "Video on demand"               video_frames
curl -s -m 5 -X POST "$UI_URL/video_stop" >/dev/null 2>&1

cleanup

if grep -q 'exited cleanly' "$STOP_LOG"; then
    RESULTS+=("PASS|Clean shutdown|$(grep -o 'exited cleanly.*' "$STOP_LOG")")
else
    RESULTS+=("FAIL|Clean shutdown|$(tail -1 "$STOP_LOG")")
fi
errors=$(grep -c -E 'Traceback|ImportError' "$LOG" 2>/dev/null)
if [[ "${errors:-0}" == 0 ]]; then
    RESULTS+=("PASS|No Python errors|")
else
    RESULTS+=("FAIL|No Python errors|$errors traceback(s) in log")
fi

# ── Report ────────────────────────────────────────────────────────────────
echo ""
echo "Results:"
failures=0
for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name detail <<< "$r"
    printf '  %-4s  %-30s %s\n' "$status" "$name" "$detail"
    [[ "$status" == FAIL ]] && failures=$(( failures + 1 ))
done

echo ""
if (( failures == 0 )); then
    echo "SMOKE TEST PASSED"
    rm -rf "$WORK_DIR"
    exit 0
fi
echo "SMOKE TEST FAILED ($failures check(s)). Logs kept in: $WORK_DIR"
exit 1
