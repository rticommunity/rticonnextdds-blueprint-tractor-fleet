# SPDX-FileCopyrightText: 2026 Real-Time Innovations, Inc.
# SPDX-License-Identifier: Apache-2.0

# Common fleet configuration — shared across all languages.
# Sourced by the launch scripts in scripts/.
#
# Change the shared deployment defaults here and every language picks them up.

# ── DDS domain ─────────────────────────────────────────────────────────
# Existing environment values override these defaults. Export is required so
# Connext can expand DOMAIN_TAG while loading the XML configuration.
export DOMAIN_ID="${DOMAIN_ID:-0}"
export DOMAIN_TAG="${DOMAIN_TAG:-tractor-fleet-salinas-CA}"

# ── Tractors ────────────────────────────────────────────────────────────
TRACTORS=("tractor1" "tractor2" "tractor3" "tractor4" "tractor5")

# ── Charging stations: "name dock_x dock_y" ─────────────────────────────
STATIONS=(
  "station1 8 92"
  "station2 92 8"
)

# ── Flask UI ────────────────────────────────────────────────────────────
UI_PORT=5000
