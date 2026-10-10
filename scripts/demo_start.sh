#!/bin/bash
# SPDX-FileCopyrightText: 2026 Real-Time Innovations, Inc.
# SPDX-License-Identifier: Apache-2.0

# Script to run the Connext DDS tractor fleet demo.
#
# DDS discovery is automatic — no port lists, no manual configuration.
# Fleet participants use the configured DOMAIN_TAG. Participants
# discover each other when both the numeric domain ID and domain tag match.
#
# Usage (from the repository root; works from any directory):
#   scripts/demo_start.sh                  - Same as 'all' (default)
#   scripts/demo_start.sh all              - Run stations + tractors + UI
#   scripts/demo_start.sh tractors         - Run all tractors in background
#   scripts/demo_start.sh stations         - Run all stations in background
#   scripts/demo_start.sh ui               - Launch the fleet dashboard UI
#   scripts/demo_start.sh persistence      - Run RTI Persistence Service
#   scripts/demo_start.sh tractor <name>   - Run a single tractor
#   scripts/demo_start.sh station <name>   - Run a single station
#
# Examples (separate VS Code terminals):
#   Terminal 1:  scripts/demo_start.sh stations
#   Terminal 2:  scripts/demo_start.sh tractors
#   Terminal 3:  scripts/demo_start.sh ui

# Monitoring Library 2.0 defaults to TRUE; set it to FALSE to disable it.
export RTI_MONITORING2_ENABLE="${RTI_MONITORING2_ENABLE:-TRUE}"
# RTI Persistence Service, started in 'all' mode:
#   AUTO        start it if a Connext installation provides it (default)
#   FORCED_ON   always start it; fail if it is not installed
#   FORCED_OFF  never start it
DEMO_RUN_PERSISTENCE_SERVICE="$(echo "${DEMO_RUN_PERSISTENCE_SERVICE:-AUTO}" | tr '[:lower:]' '[:upper:]')"
export DEMO_RUN_PERSISTENCE_SERVICE

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_DIR="$REPO_DIR/python"
# The Python applications are launched from their own directory.
cd "$PYTHON_DIR"

# Activate the project venv if not already active
VENV_DIR="$REPO_DIR/venv"
if [ -z "$VIRTUAL_ENV" ] && [ -f "$VENV_DIR/bin/activate" ]; then
    source "$VENV_DIR/bin/activate"
fi

# ── Fleet configuration ──────────────────────────────────────────────────
# Sets DOMAIN_ID, DOMAIN_TAG, TRACTORS[], STATIONS[], and UI_PORT.
source "$REPO_DIR/shared/fleet_common.sh"
# ─────────────────────────────────────────────────────────────────────────

# RTI Persistence Service storage, shared by every language's applications.
# PERSISTENCE_STORAGE_DIR overrides it (smoke_test.sh uses a temporary one).
STORAGE_DIR="${PERSISTENCE_STORAGE_DIR:-$REPO_DIR/persistent_data}"

# Helper: look up station dock coords by name → "x y"
station_lookup() {
    for (( i=0; i<${#STATIONS[@]}; i++ )); do
        read -r sname sx sy <<< "${STATIONS[$i]}"
        [[ "$sname" == "$1" ]] && echo "$sx $sy" && return
    done
    echo "Error: unknown station '$1'. Known: $(printf '%s ' "${STATIONS[@]}")" >&2; exit 1
}

echo "Connext DDS Tractor Fleet Demo"
echo "====================================="
echo ""


# ── Connext license ────────────────────────────────────────────────────────
# No DYLD_LIBRARY_PATH/LD_LIBRARY_PATH needed: the rti.connext Python wheel
# bundles its own native libraries, and rtipersistenceservice has its own
# rpath baked in. Exporting it here would shadow the wheel's bundled libs
# with the system Connext install's, which can be ABI-incompatible.
if [[ -n "${NDDSHOME:-}" ]]; then
    export RTI_LICENSE_FILE="${RTI_LICENSE_FILE:-$NDDSHOME/rti_license.dat}"
fi
# Without a Connext installation, RTI_LICENSE_FILE must be set directly.
if [[ -z "${RTI_LICENSE_FILE:-}" ]]; then
    echo "ERROR: RTI_LICENSE_FILE is not set."
    echo "       Export RTI_LICENSE_FILE=/path/to/rti_license.dat (see the README)."
    exit 1
fi
if [[ ! -f "$RTI_LICENSE_FILE" ]]; then
    echo "ERROR: License file not found: $RTI_LICENSE_FILE"
    exit 1
fi

# Python uses the native libraries bundled in the rti.connext wheel, so the
# applications need no Connext installation. NDDSHOME is needed only to
# locate RTI Persistence Service; it is intentionally not added to the
# native-library search path.
persistence_service_available() {
    [[ -n "${NDDSHOME:-}" && -x "$NDDSHOME/bin/rtipersistenceservice" ]]
}

# Framed notice for AUTO mode when Persistence Service isn't available. 'all'
# prints it once the dashboard is up, so it isn't lost in startup output.
persistence_notice() {
    local line="=============================================================================="
    echo ""
    echo "$line"
    if [[ -z "${NDDSHOME:-}" ]]; then
        echo " RTI Persistence Service not started: no Connext installation found."
    else
        echo " RTI Persistence Service not started: not found in NDDSHOME:"
        echo "   $NDDSHOME/bin/rtipersistenceservice"
    fi
    echo " The demo runs without it, but coverage trails won't survive tractor restarts."
    echo " To enable it, see \"Optional: Full Connext Installation\" in README.md."
    echo " To hide this notice: export DEMO_RUN_PERSISTENCE_SERVICE=FORCED_OFF"
    echo "$line"
    echo ""
}

require_persistence_service() {
    if [[ -z "${NDDSHOME:-}" ]]; then
        echo "ERROR: NDDSHOME is required to start RTI Persistence Service."
        echo "       Source setup.sourceme (repository root) or export NDDSHOME explicitly."
        exit 1
    fi
    if [[ ! -x "$NDDSHOME/bin/rtipersistenceservice" ]]; then
        echo "ERROR: RTI Persistence Service not found or not executable:"
        echo "       $NDDSHOME/bin/rtipersistenceservice"
        echo "       Correct NDDSHOME and try again."
        exit 1
    fi
}

case "${1:-all}" in
    ui)
        echo "Starting Fleet Dashboard UI on port $UI_PORT..."
        echo "DDS domain $DOMAIN_ID / tag $DOMAIN_TAG"
        echo ""
        python fleet_ui.py --domain "$DOMAIN_ID" --ui-port "$UI_PORT"
        ;;
    persistence)
        require_persistence_service
        echo "RTI Persistence Service"
        echo "====================================="
        echo "NDDSHOME:  $NDDSHOME"
        mkdir -p "$STORAGE_DIR"
        export STORAGE_DIRECTORY="$STORAGE_DIR"
        echo "Storage:   $STORAGE_DIR"
        echo "Config:    tractorFleetDisk (domain tag: $DOMAIN_TAG)"
        echo ""
        echo "Press Ctrl+C to stop"
        echo ""
        exec "$NDDSHOME/bin/rtipersistenceservice" \
            -cfgFile "$REPO_DIR/fleet_persistence.xml" \
            -cfgName tractorFleetDisk \
            -domainId "$DOMAIN_ID"
        ;;
    tractor)
        TRACTOR_NAME="$2"
        if [ -z "$TRACTOR_NAME" ]; then
            echo "Error: missing tractor name.  Usage: $0 tractor <name>"
            echo "Example: $0 tractor tractor1"
            exit 1
        fi
        echo "Starting tractor $TRACTOR_NAME (domain $DOMAIN_ID)..."
        echo "DDS discovery is automatic — no peer configuration needed"
        echo ""
        python tractor_node.py --id "$TRACTOR_NAME" --domain "$DOMAIN_ID"
        ;;
    station)
        STATION_NAME="$2"
        if [ -z "$STATION_NAME" ]; then
            echo "Error: missing station name.  Usage: $0 station <name>"
            echo "Available: $(printf '%s ' "${STATIONS[@]}")"
            exit 1
        fi
        read -r sx sy <<< "$(station_lookup "$STATION_NAME")"
        echo "Starting $STATION_NAME (domain $DOMAIN_ID, dock at $sx,$sy)..."
        python charging_station.py --id "$STATION_NAME" --domain "$DOMAIN_ID" \
            --dock-x "$sx" --dock-y "$sy"
        ;;
    tractors)
        echo "Starting all tractors in background..."
        echo "DDS domain $DOMAIN_ID"
        echo ""

        PIDS=()
        for NAME in "${TRACTORS[@]}"; do
            echo "  Starting $NAME"
            python tractor_node.py --id "$NAME" --domain "$DOMAIN_ID" &
            PIDS+=($!)
            sleep 2
        done

        cleanup() {
            echo ""
            echo "Stopping all tractors..."
            kill "${PIDS[@]}" 2>/dev/null
            exit 0
        }
        trap cleanup SIGINT SIGTERM

        echo ""
        echo "All tractors started.  PIDs: ${PIDS[*]}"
        echo "Press Ctrl+C to stop"
        wait
        ;;
    stations)
        echo "Starting all stations in background..."
        echo "DDS domain $DOMAIN_ID"
        echo ""

        PIDS=()
        for (( si=0; si<${#STATIONS[@]}; si++ )); do
            read -r sname sx sy <<< "${STATIONS[$si]}"
            echo "  Starting $sname (dock at $sx,$sy)"
            python charging_station.py --id "$sname" --domain "$DOMAIN_ID" \
                --dock-x "$sx" --dock-y "$sy" &
            PIDS+=($!)
        done

        cleanup() {
            echo ""
            echo "Stopping all stations..."
            kill "${PIDS[@]}" 2>/dev/null
            exit 0
        }
        trap cleanup SIGINT SIGTERM

        echo ""
        echo "All stations started.  PIDs: ${PIDS[*]}"
        echo "Press Ctrl+C to stop"
        wait
        ;;
    all)
        echo "Starting all tractors + stations in background..."
        echo "DDS domain $DOMAIN_ID / tag $DOMAIN_TAG"
        echo ""
        echo "TIP: For separate terminals, run each component individually:"
        echo "  $0 tractor <name>"
        echo "  $0 station <name>"
        echo "  $0 ui"
        echo ""

        PIDS=()

        case "$DEMO_RUN_PERSISTENCE_SERVICE" in
            AUTO)
                if persistence_service_available; then
                    START_PERSISTENCE=TRUE
                else
                    START_PERSISTENCE=FALSE
                fi
                ;;
            FORCED_ON)
                require_persistence_service
                START_PERSISTENCE=TRUE
                ;;
            FORCED_OFF)
                START_PERSISTENCE=FALSE
                echo "RTI Persistence Service not started: DEMO_RUN_PERSISTENCE_SERVICE=FORCED_OFF."
                echo "Coverage trails will not survive tractor restarts."
                ;;
            *)
                echo "ERROR: DEMO_RUN_PERSISTENCE_SERVICE must be AUTO, FORCED_ON, or FORCED_OFF"
                echo "       (got '$DEMO_RUN_PERSISTENCE_SERVICE')."
                exit 1
                ;;
        esac

        if [ "$START_PERSISTENCE" == "TRUE" ]; then
            # Launch Persistence Service first so coverage is captured from the start
            mkdir -p "$STORAGE_DIR"
            export STORAGE_DIRECTORY="$STORAGE_DIR"
            echo "  Starting RTI Persistence Service (storage: $STORAGE_DIR)"
            "$NDDSHOME/bin/rtipersistenceservice" \
                -cfgFile "$REPO_DIR/fleet_persistence.xml" \
                -cfgName tractorFleetDisk \
                -domainId "$DOMAIN_ID" &
            PIDS+=($!)
            sleep 1
        fi

        # Launch charging stations
        for (( si=0; si<${#STATIONS[@]}; si++ )); do
            read -r sname sx sy <<< "${STATIONS[$si]}"
            echo "  Starting $sname (dock at $sx,$sy)"
            python charging_station.py --id "$sname" --domain "$DOMAIN_ID" \
                --dock-x "$sx" --dock-y "$sy" &
            PIDS+=($!)
        done
        sleep 1

        for NAME in "${TRACTORS[@]}"; do
            echo "  Starting $NAME"
            python tractor_node.py --id "$NAME" --domain "$DOMAIN_ID" &
            PIDS+=($!)
            sleep 2
        done

        if [ "$DEMO_RUN_PERSISTENCE_SERVICE" == "AUTO" ] && [ "$START_PERSISTENCE" != "TRUE" ]; then
            # Print the notice once the dashboard answers, after its startup
            # output, so it doesn't scroll away. The UI stays in the
            # foreground, so Ctrl+C still reaches it.
            (
                for _ in $(seq 1 60); do
                    if curl -s -o /dev/null "http://localhost:$UI_PORT/"; then
                        persistence_notice
                        break
                    fi
                    sleep 0.5
                done
            ) &
        fi
        echo "Starting Fleet Dashboard UI on port $UI_PORT..."
        echo "DDS domain $DOMAIN_ID / tag $DOMAIN_TAG"
        echo ""
        python fleet_ui.py --domain "$DOMAIN_ID" --ui-port "$UI_PORT"

        cleanup() {
            echo ""
            echo "Stopping all tractors, stations, and persistence service..."
            kill "${PIDS[@]}" 2>/dev/null
            exit 0
        }
        trap cleanup SIGINT SIGTERM

        echo ""
        echo "All participants started.  PIDs: ${PIDS[*]}"
        echo "Press Ctrl+C to stop everything"
        echo ""
        echo "To launch the dashboard in another terminal:"
        echo "  $0 ui"
        wait
        ;;
    -h|--help|*)
        echo "Usage:"
        echo "  $0 all              Run stations + tractors + UI"
        echo "  $0 tractors           Run all tractors in background"
        echo "  $0 stations         Run all stations in background"
        echo "  $0 ui               Launch the dashboard UI"
        echo "  $0 persistence      Run RTI Persistence Service"
        echo "  $0 tractor <name>     Run a single tractor"
        echo "  $0 station <name>   Run a single station"
        echo ""
        echo "DDS domain: $DOMAIN_ID / tag: $DOMAIN_TAG"
        echo "Tractors: ${TRACTORS[*]}"
        echo "Stations: $(printf '%s ' "${STATIONS[@]}")"
        echo ""
        echo "No port lists needed — DDS SPDP handles discovery."
        exit 0
        ;;
esac
