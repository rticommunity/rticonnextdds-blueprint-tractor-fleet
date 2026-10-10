#!/bin/bash
# SPDX-FileCopyrightText: 2026 Real-Time Innovations, Inc.
# SPDX-License-Identifier: Apache-2.0

# demo_stop.sh — Stop running tractor fleet demo processes.
# No ports to free — DDS uses multicast, not explicit listen ports.
#
# Sends SIGTERM, which every application handles like Ctrl-C (closing its
# DDS entities), waits for the processes to exit, and force-kills any that
# are still running after GRACE_SECONDS.
#
# Usage (from the repository root; works from any directory):
#   scripts/demo_stop.sh                   # stop everything
#   scripts/demo_stop.sh tractors          # stop all tractor nodes
#   scripts/demo_stop.sh stations          # stop all charging stations
#   scripts/demo_stop.sh ui                # stop the dashboard UI
#   scripts/demo_stop.sh persistence       # stop RTI Persistence Service
#   scripts/demo_stop.sh tractor <name>    # stop a single tractor
#   scripts/demo_stop.sh station <name>    # stop a single station
#
# Environment:
#   GRACE_SECONDS  Seconds to wait before force-killing (default 10). With
#                  Monitoring Library 2.0 enabled, finalizing the participant
#                  factory takes several seconds per process.

GRACE_SECONDS="${GRACE_SECONDS:-10}"

usage() {
    echo "Usage: $0 [all|tractors|stations|ui|persistence|tractor <name>|station <name>]"
    exit 1
}

# Process command-line patterns (extended regular expressions for pgrep -f).
# Requiring the Python interpreter before the script name keeps editors and
# pagers that have the file open (e.g. "vim python/tractor_node.py") from
# matching. Persistence Service matches both its launcher script and its
# application binary through the -cfg arguments demo_start.sh passes.
PY='[Pp]ython[0-9.]* .*'
TRACTOR="${PY}tractor_node\.py"
STATION="${PY}charging_station\.py"
UI="${PY}fleet_ui\.py"
PERSISTENCE='rtipersistenceservice(app)? .*-cfg'

case "${1:-all}" in
    all)         PATTERNS=("$TRACTOR" "$STATION" "$UI" "$PERSISTENCE") ;;
    tractors)    PATTERNS=("$TRACTOR") ;;
    stations)    PATTERNS=("$STATION") ;;
    ui)          PATTERNS=("$UI") ;;
    persistence) PATTERNS=("$PERSISTENCE") ;;
    tractor)     [ -n "$2" ] || usage; PATTERNS=("$TRACTOR --id $2( |\$)") ;;
    station)     [ -n "$2" ] || usage; PATTERNS=("$STATION --id $2( |\$)") ;;
    *)           usage ;;
esac

# Print the PIDs of every process matching any pattern.
find_pids() {
    for pattern in "${PATTERNS[@]}"; do
        pgrep -f "$pattern" 2>/dev/null
    done
}

stopped=0
for pid in $(find_pids); do
    echo "Stopping PID $pid: $(ps -p "$pid" -o args= 2>/dev/null | cut -c1-100)"
    kill "$pid" 2>/dev/null && stopped=$((stopped + 1))
done

if [ "$stopped" -eq 0 ]; then
    echo "No matching demo processes found."
    exit 0
fi

echo "Sent SIGTERM to $stopped process(es). Waiting up to ${GRACE_SECONDS}s for clean exit..."
waited=0
while [ -n "$(find_pids)" ] && [ "$waited" -lt "$GRACE_SECONDS" ]; do
    sleep 1
    waited=$((waited + 1))
done

# Escalate to SIGKILL for any survivors.
survivors=0
for pid in $(find_pids); do
    echo "Force-killing PID $pid (still running ${GRACE_SECONDS}s after SIGTERM)"
    kill -9 "$pid" 2>/dev/null
    survivors=$((survivors + 1))
done

if [ "$survivors" -gt 0 ]; then
    echo "Force-killed $survivors process(es)."
else
    echo "All processes exited cleanly after ${waited}s."
fi
