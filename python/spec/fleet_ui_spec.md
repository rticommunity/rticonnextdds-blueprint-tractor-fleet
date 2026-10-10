# Tractor Fleet Dashboard UI — Specification

> This document specifies the [`python/fleet_ui.py`](../fleet_ui.py)
> application. DDS types are defined by [`fleet_types.idl`](../../fleet_types.idl)
> and generated in [`python/fleet_types.py`](../fleet_types.py); endpoint QoS
> comes from [`fleet_qos.xml`](../../fleet_qos.xml). Relevant command, coverage, and
> video behavior is implemented by [`python/tractor_node.py`](../tractor_node.py).

---

## 1  Purpose

A single-page live web dashboard that subscribes to a fleet of tractor nodes and
charging stations via DDS, displays real-time Kinematic State, Operational
State, Intent, Telemetry, Charging Station status, coverage trails, and selected
tractor video, and lets the operator send commands through an interactive
browser UI.

The UI uses one DDS DomainParticipant and shared topic readers keyed by
`tractor_id`. Tractors and stations are discovered through SPDP.
Commands are sent via `rti.rpc.Requester`. The `tractor_id` inside the
`CommandRequest` names the target tractor, or `ALL` for every tractor; each
tractor's `SimpleReplier` reads requests through a content filter, so a
request reaches only the tractors it addresses.

**Data reception model:** The UI has one `DomainParticipant` and seven
`DataReader` objects: six tractor streams (including the partition-selected
video stream) and one charging-station stream. One daemon thread calls `take()`
on all seven readers sequentially, then sleeps for 50 ms, so the polling loop
runs at no more than 20 cycles per second. DDS delivers samples from matched
writers through one reader per topic type; keyed `tractor_id` or `station_id`
fields identify the source.

---

## 2  Technology Stack

| Layer | Technology |
|-------|-----------|
| Language | Python 3.14.3+ |
| Middleware | RTI Connext DDS 7.7.0+ (`rti.connextdds`, `rti.rpc`) |
| Type generation | `rtiddsgen -language python fleet_types.idl` → `fleet_types.py` |
| QoS configuration | `fleet_qos.xml` — Pattern-based profiles (`BuiltinQosLib::Pattern.*`) |
| Web framework | Flask (single-file, `render_template_string`) |
| Live updates | Server-Sent Events (SSE) at 5 Hz |
| Frontend | Inline HTML + CSS + vanilla JavaScript in a single template string |
| Canvas | HTML5 `<canvas>` for the 2-D position map |
| Concurrency | Python `threading` (daemon threads) |

Runtime dependencies are the Python standard library, RTI Connext Python APIs,
and Flask. The browser UI uses inline HTML, CSS, and JavaScript.

### Technology Summary

| Concern | Approach |
|---------|-------------|
| Tractor data streams | 6 DDS DataReaders: kinematic, operational, intent, telemetry, coverage, and partition-selected video |
| Charging station stream | 1 DDS DataReader on `StationStatus` for all matched stations |
| Discovery and matching | SPDP participant discovery plus SEDP endpoint discovery; UI counts come from received keyed data |
| Resilience behavior | DDS discovery, liveliness, and topic QoS |
| Commands | `rti.rpc.Requester` — `send_request()` + `receive_replies()` |
| Ingestion | One daemon polling thread; seven sequential `take()` calls followed by a 50 ms sleep |
| Video | DDS `LiveVideo` reader selected by Subscriber partition |
| Presence display | `live` / `stale` / `offline` from the `KinematicState` deadline status and instance states, polled; offline tractors removed after 10 s |
| Direct external imports | `rti.connextdds`, `rti.rpc`, `flask` |

---

## 3  Command-Line Interface

```
python fleet_ui.py [--domain DOMAIN_ID] [--ui-port PORT]
```

| Argument | Type | Default | Description |
|----------|------|---------|-------------|
| `--domain` | int | `0` | DDS Domain ID (must match tractor nodes and charging stations) |
| `--ui-port` | int | `5000` | HTTP port for the web dashboard |

The CLI configures the DDS domain and browser-facing HTTP port. DDS SPDP
discovers participants on the domain, and incoming `tractor_id` key values
identify tractors at runtime.

At startup `main()`:

1. Parses arguments.
2. Creates a `FleetStateStore()`.
3. Creates a `DdsFleetClient(store, domain_id)`.
4. Calls `client.start()` → creates the DDS participant, seven readers, polling
  thread, and command Requester.
5. Creates the Flask app and runs Flask on `0.0.0.0:<ui-port>` with threaded
  request handling.

The participant uses the configured domain tag, SPDP/SEDP discovery, and UDPv4
transport from `ParticipantProfile`. The DDS client creates its readers and
command requester and processes samples from matched endpoints.

---

## 4  Backend Architecture

The backend separates **application state** from **DDS integration**:

- **`FleetStateStore`** — thread-safe application-state store consumed by the
  SSE and command routes.
- **`DdsFleetClient`** — owns the DDS DomainParticipant, DataReaders, and
  Requester.  Pushes plain Python dicts into the store; sends commands on
  behalf of the UI.

### 4.1  `FleetStateStore` class

A thread-safe store of normalized tractor, station, and coverage state, updated
by the DDS polling thread.

#### Data stores (all protected by a single `threading.Lock`)

| Dict | Key | Value |
|------|-----|-------|
| `kinematic` | tractor_id (str) | `{x, y, z, vx, vy, vz, heading, ts}` |
| `operational` | tractor_id | `{status, battery, ts}` |
| `intent` | tractor_id | `{type, target_x, target_y, ts, waypoints?, waypoint_index?}` |
| `telemetry` | tractor_id | `{cpu, memory, temperature, signal_strength, ts}` |
| `charging` | station_id (str) | `{station_id, dock_tractor, queue, dock_x, dock_y}` |
| `coverage` | tractor_id | arrival-ordered list of `{x, y}` |
| `presence` | tractor_id | `"live"`, `"stale"` (deadline missed), or `"offline"` (writer gone) |

Every `ts` is `time.time()` at UI ingestion, not a DDS SampleInfo timestamp.
DDS `Intent.target_position.x/y` is normalized to store fields
`target_x/target_y`; the DDS type itself has no `target_x` or `target_y` fields.
Coverage entries have no sequence field.

#### Read methods

- **`snapshot()` → dict** — Returns a JSON-serialisable copy of all data stores.
  Builds a merged `state` dict combining kinematic and operational data for
  each tractor, with each tractor's `presence`. Includes `presence`,
  `presence_seconds` (seconds since the last position update for a stale
  tractor, until removal for an offline one; computed on the server, so the
  browser clock doesn't matter), `charging`, `coverage`, and `domain_id`. This is what the SSE endpoint sends
  every 200 ms.
- **`known_tractors()` → list[str]** — Returns sorted list of tractor_ids that have
  kinematic data.

#### Write methods (called by the DDS client)

- **`update_kinematic(tractor_id, data)`** — Store kinematic state dict and set
  presence to `live`.
- **`update_operational(tractor_id, data)`** — Store operational state dict.
- **`update_intent(tractor_id, data)`** — Store an intent dict with path waypoints.
- **`update_telemetry(tractor_id, data)`** — Store a telemetry dict.
- **`update_charging(station_id, data)`** — Store a charging station status dict.
- **`update_coverage(tractor_id, x, y)`** — Append `{x, y}` to the tractor trail.
- **`clear_coverage()`** — Clear all in-memory coverage trails.
- **`set_presence(tractor_id, presence)`** — Record and log a presence change.
  `stale` applies only to a `live` tractor; `offline` records the time.
- **`prune_offline(grace)`** — Call `remove_tractor()` for every tractor that
  has been offline longer than `grace` seconds (`OFFLINE_GRACE_S` = 10).
- **`remove_tractor(tractor_id)`** — Remove the tractor's kinematic,
  operational, intent, telemetry, and presence entries. Its coverage trail
  stays.

DDS samples and command requests identify tractors by `tractor_id`. Station
values are retained indefinitely; stations are not pruned.

### 4.2  `DdsFleetClient` class

Owns the DDS DomainParticipant and all DDS entities.  Holds a reference to a
`FleetStateStore`.

#### DDS Entities

| Entity | Type | QoS Profile | Purpose |
|--------|------|-------------|---------|
| `participant` | `DomainParticipant` | `ParticipantProfile` | Named/role-named `FleetUI`; one participant for the UI |
| Topics | 7 × `Topic` | — | One for every reader type |
| General subscriber | `Subscriber` | default | Owns six non-video readers |
| Video subscriber | `Subscriber` | partition initially `__NONE__` | Owns the video reader |
| Kinematic reader | `DataReader[KinematicState]` | `KinematicStateProfile` | 10 Hz position data from all tractors |
| Operational reader | `DataReader[OperationalState]` | `OperationalStateProfile` | Status/battery changes from all tractors |
| Intent reader | `DataReader[Intent]` | `IntentProfile` | Intent/path changes from all tractors |
| Telemetry reader | `DataReader[Telemetry]` | `TelemetryProfile` | 1 Hz telemetry from all tractors |
| Video reader | `DataReader[VideoFrame]` on `LiveVideo` | `VideoProfile` | Latest JPEG from the one partition-matched tractor |
| StationStatus reader | `DataReader[StationStatus]` | `StationStatusProfile` | Charging station queue state |
| Coverage reader | `DataReader[CoveragePoint]` | `CoverageProfile` | Persistent coverage points from all tractors |
| `command_requester` | `rti.rpc.Requester[CommandRequest, CommandResponse]` | `CommandProfile` | Sends commands and receives correlated responses |

#### `start()`

1. Resolve `fleet_qos.xml` path relative to the script.
2. Create `QosProvider` and `DomainParticipant`.
3. Create topics: `KinematicState`, `OperationalState`, `Intent`, `Telemetry`,
   `LiveVideo` (type `VideoFrame`), `StationStatus`, and `CoveragePoint`.
4. Create a general Subscriber with six non-video readers.
5. Create a dedicated video Subscriber whose initial partition is `__NONE__`,
   and create the seventh reader on it.
6. Start one daemon thread running `_poll_readers()`.
7. Create `rti.rpc.Requester` for commands:
   ```python
   self.command_requester = rpc.Requester(
       request_type=CommandRequest,
       reply_type=CommandResponse,
       participant=self.participant,
       service_name="TractorCommand",
       datawriter_qos=qos_provider.datawriter_qos_from_profile(
           "FleetQosLibrary::CommandProfile"),
       datareader_qos=qos_provider.datareader_qos_from_profile(
           "FleetQosLibrary::CommandProfile"),
   )
   ```

#### Polling

`_poll_readers()` sequentially invokes `_poll_kinematic()`,
`_check_kinematic_deadline()`, `store.prune_offline()`, `_poll_operational()`,
`_poll_intent()`, `_poll_telemetry()`, `_poll_video()`, `_poll_station()`, and
`_poll_coverage()`. Each poller calls `take()` and normalizes valid data. The
loop sleeps 0.05 seconds after each cycle. A cycle-wide exception handler logs
an error, skips any remaining readers in that cycle, and resumes after the
sleep.

#### Presence

Presence comes from DDS, read in the same polling loop, with no listeners:

- `_poll_kinematic()` records each valid sample's instance handle →
  `tractor_id` in `_kin_handles`. A sample without data whose instance state
  is not `ALIVE` means the tractor's writer is gone (immediately after an
  orderly shutdown, or when the 30-second liveliness lease expires after a
  crash); the tractor is marked `offline`.
- `_check_kinematic_deadline()` reads
  `requested_deadline_missed_status` from the `KinematicState` reader. When
  `total_count_change > 0`, the tractor named by `last_instance_handle` is
  marked `stale`. The 500 ms reader deadline fires repeatedly while a tractor
  is silent, so every silent tractor is reported within a few periods even
  though the status names one instance at a time.
- The next valid `KinematicState` sample makes the tractor `live` again.
- An offline tractor is removed after `OFFLINE_GRACE_S` (10 s).

The video poller stores latest JPEG bytes by tractor ID under `_video_lock`.
The coverage poller appends `CoveragePoint.x/y` to the store. Station ingestion
retains dock coordinates, docked tractor ID, and queue entries, but not
`StationStatus.is_occupied`.

#### `send_command(tractor_id, command, *, goto_x, goto_y, goto_speed, waypoints)`

1. Map command string → `Command` enum value.
2. Build optional typed parameters:
   - `CMD_GOTO` → `GotoParameters(x=goto_x, y=goto_y, speed=goto_speed)`.
   - `CMD_SET_PATH` with a truthy waypoint list →
     `SetPathParameters(waypoints=[Waypoint(x=..., y=...), ...])`.
   - `CMD_FOLLOW_PATH` / `CMD_RESUME` with speed > 0 →
     `GotoParameters(speed=goto_speed)`.
   - Otherwise both optional parameter fields remain `None`.
3. Create `CommandRequest(tractor_id=tractor_id, command=cmd_enum,
   goto_params=goto_params, set_path_params=set_path_params)`.
4. Call `command_requester.send_request(request)`.
5. Wait up to five seconds with `receive_replies(...,
   related_request_id=request_id)` so replies are correlated to this request.
6. Collect replies and return the one whose `tractor_id` matches the target.
   With the tractors' content filters only the target replies; replies from
   a tractor without the filter ("not addressed to me") are ignored.
7. Return `{success, description, resulting_status, resulting_intent}`.

The command requester is long-lived and reused for all requests. DDS request
metadata performs request/reply correlation; coordinates, speed, and waypoints
cross DDS only as the typed optional IDL members of `CommandRequest`. The
`tractor_id` field determines which tractors receive and act on each request.

On the current tractor implementation, `STOP` enters idle and zeros planar
velocity; `FOLLOW_PATH` resumes path motion and resets coverage activation;
`GOTO` applies typed coordinates and an optional positive speed; `RESUME`
restores or derives movement/holding state; `SET_PATH` requires at least two
typed waypoints but does not itself switch intent; and `CHARGE` starts charging
negotiation on a tractor daemon thread. GOTO/FOLLOW_PATH abort an existing
charge slot before changing tasks.

#### `send_command_all(command, *, goto_x, goto_y, goto_speed, waypoints)`

Sends **one** DDS request with `tractor_id = "ALL"` (`ALL_TRACTORS`), built by
`_build_request()` like a single-tractor command. Every tractor's
`SimpleReplier` receives it and acts on it. The client calls
`wait_for_replies(5 s, min_count = len(store.known_tractors()),
related_request_id = request_id)` and then `take_replies(request_id)`, so it
waits until every known tractor has replied or five seconds pass. It returns
`{broadcast, command, requests_sent: 1, success, description, results}`;
`results` holds every reply (including tractors the UI has not seen yet) and
marks known tractors that didn't reply as `no reply`. `success` is true only
if at least one tractor replied and all replies succeeded.

#### `get_video_frame(tractor_id)` → bytes or None

Returns the most recent JPEG `frame_data` for the given tractor from the
polling thread's lock-protected buffer. Returns `None` if no frame is available.

#### Video partition selection

Each tractor places its `LiveVideo` writer on a Publisher partition equal to
its tractor ID. The UI video Subscriber starts on `__NONE__`, which matches no
tractor. `select_video_tractor()` clears old frames, increments a generation
counter, and changes the Subscriber partition to the selected ID.
`deselect_video()` restores `__NONE__`, increments the generation, and clears
the frame buffer. The tractor's video worker polls
`publication_matched_status.current_count`; it renders and publishes at about
5 fps only while matched. The browser Stop button explicitly POSTs
`/video_stop`; merely disconnecting an MJPEG response does not reset the DDS
partition.

### 4.3  Flask routes

| Route | Method | Description |
|-------|--------|-------------|
| `/` | GET | Serves the inline HTML dashboard |
| `/stream` | GET | SSE endpoint — yields `data: <json>\n\n` every 200 ms (reads from `store.snapshot()`) |
| `/command` | POST | Accepts JSON `{tractor_id, command, goto_x?, goto_y?, goto_speed?, waypoints?}`, calls `client.send_command()` or `client.send_command_all()` (when `tractor_id == "ALL"`), returns JSON result |
| `/video_feed/<tractor_id>` | GET | Selects the tractor's Subscriber partition and emits the latest buffered frame as MJPEG at a 0.2-second loop cadence; exits when the video generation changes or the response ends |
| `/video_stop` | POST | Explicitly restores the Subscriber partition to `__NONE__`, increments the generation, clears frames, and returns `{success: true}` |
| `/clear_coverage` | POST | Clears the in-memory coverage store and returns `{success: true}` |
| `/ground_texture.jpg` | GET | Serves `field1_map.jpg` as the 2D canvas background texture |

`/command` force-parses JSON, defaults missing coordinate/speed values to zero,
and converts them with `float()`. It performs no separate bounds, tractor-ID,
or waypoint schema validation. The MJPEG loop may emit the same buffered frame
again when no newer frame has arrived. These JSON fields are the browser-to-Flask
HTTP contract; the DDS request uses the typed IDL command fields described above.

---

## 5  Frontend Layout

Single-page, dark theme (Catppuccin Mocha palette).  Font: `Menlo` / `Consolas`
monospace, 13 px base.

The frontend consumes JSON snapshots from the SSE `/stream` endpoint and sends
commands to the `/command` POST endpoint.

### Overall structure

```
┌──────────────────────────────────────────────────────────────┐
│  Tractor Fleet Dashboard — RTI Connext DDS    [stats badge]  │
├────────────────────────────────┬─────────────────────────────┤
│                                │  ▸ Commands                 │
│                                │  ▸ Onboard Camera           │
│         Position Map           │  ▸ Kinematic State          │
│        (canvas, flex:1)        │  ▸ Operational State        │
│                                │  ▸ Intent                   │
│                                │  ▸ Telemetry                │
│                                │  ▸ Charging Stations        │
│                                │  ▸ DDS Status               │
└────────────────────────────────┴─────────────────────────────┘
```

- Left: `.map-panel` — flex:1, contains a `<canvas>` that fills available space.
- Right: `.data-panel` — fixed width 480 px, scrollable, stacked sections.
- Header: Stats badge shows `N tractors · S stations · DDS domain D`.
- All sections are **collapsible** (click heading to toggle).

### 5.1  Color Palette

Fixed palette of 10 colours, assigned by cycling through in order of first
appearance.

---

## 6  Data Tables (Right Panel)

All tables update every SSE frame (5 Hz).  Rows are sorted alphabetically by
tractor name.

### 6.1  Command Panel

Tractor dropdown, X/Y/Speed inputs, GOTO/PATH/STOP/RESUME/CHARGE buttons.
The dropdown is populated from merged `state` keys and ends with `ALL tractors`
(value `ALL`).
X/Y default to 50 and speed to 2.0. PATH sends `FOLLOW_PATH`; clicking the map
only fills X/Y and shows a crosshair, so GOTO still requires the button.
`ALL tractors` sends one broadcast request (§4.2); the result line shows
"1 DDS request, N replies" and a ✓/✗ per tractor. Coverage toggle
and Clear Coverage controls are in this panel.

### 6.2  Onboard Camera Panel

Start/Stop buttons and a video container.  The `/video_feed/<rid>` route
selects the matching DDS partition and serves MJPEG. Stop removes the image and
POSTs `/video_stop`, which unmatches video by restoring `__NONE__`.

### 6.3  Kinematic State Table

Columns: tractor name (blue bold), `(x, y)` position, speed (u/s), heading (°).

### 6.4  Operational State Table

Columns: tractor name, status string (with `⚡ CHARGING` in peach/bold), battery
% (colour-coded: green > 50, yellow > 20, red ≤ 20).

### 6.5  Intent Table

Columns: tractor name, intent type string, `(target_x, target_y)`.
These are normalized store names sourced from DDS
`Intent.target_position.x/y`.

### 6.6  Telemetry Table

Columns: tractor name, CPU %, MEM %, temperature °C, signal strength %.

Footer note: *"DDS: zero per-tractor connections — one write() per tractor
reaches every matched reader"*.

### 6.7  Charging Stations Panel

Dock status display and queue rendering with rank icons (🔌 Charging, 🚜 En
route, ⏳ Waiting, … Pending).  Data comes from the `StationStatus` DDS
topic.

### 6.8  DDS Status Panel

The panel shows:
- DDS domain ID.
- Number of discovered tractors (keys of the merged `state`).
- Number of tractors with no updates (`stale`, deadline missed).
- Number of offline tractors (writer gone).
- Number of discovered stations (from charging data).

Presence counts come from the DDS deadline status and instance states (§4.2).
The tractor and station counts are store key counts, not DDS built-in
discovery data.

---

## 7  Canvas Position Map

Coordinate system spans a 0–100 arena, with a fixed margin, Y-axis inversion,
background grid, ground texture, and consistent tractor colour assignment.

### 7.1  Charging Station Icons

Glowing pad with green/blue/orange state, ⚡ emoji, queue count badge.

### 7.2  Per-Tractor Rendering

Drawing order: path route (dashed loop with waypoint dots), intent arrow,
tractor icon with status beacon, GOTO crosshair, flash marker.

A `stale` tractor is drawn normally with a solid amber ring around it that
pulses (radius and opacity, 1.2 s period). An `offline` tractor is drawn in
grey at 70% opacity inside a static grey dashed ring, at its last known
position, without route or intent arrow. `drawPresenceRing()` draws both
rings; `drawTractor()` takes a `fade` factor that scales every alpha it sets.
The map shows no presence text. The Operational State table carries the
labels with countdowns from `presence_seconds`: "⚠ no update for N s" for a
stale tractor, and "offline · removed in N s" on a dimmed row for an offline
one.

Coverage is drawn before tractors from the SSE `coverage` map. Trails use the
tractor color, 4 px rounded lines, and 0.45 opacity. Consecutive points more
than five arena units apart start a new segment.

### 7.3  Mouse Interactions

Single click fills the GOTO inputs after a 250 ms double-click delay; it does not
send. Dragging sends `SET_PATH` on mouseup. Double-click inserts into the nearest
route and sends `SET_PATH`. ⌥+click removes a waypoint and sends `SET_PATH`, but
the frontend refuses to leave fewer than two points. Leaving the canvas cancels
an active drag without sending.

### 7.4 Coverage lifecycle

`CoveragePoint` is published by a tractor only during active path work after it
has reached a waypoint, while no charge is requested, and at least one arena
unit from the previous published point. The UI appends `{x, y}` samples in
arrival order. `/clear_coverage` clears only the UI process's in-memory map; it
does not clear DDS writer or Persistence Service history. Newly received points
repopulate the map, and a restarted reader can receive retained persistent
history. The Coverage toggle affects browser rendering only. `CoverageProfile`
uses RELIABLE, PERSISTENT durability, KEEP_LAST depth 1000, and bounded resource
limits on both writer and reader; it does not use the base profile's
TRANSIENT_LOCAL durability.

---

## 8  SSE Data Flow

```
┌───────────────┐  DDS pub-sub topics   ┌──────────────────────┐
│ Tractor Nodes │ ────────────────────► │ DdsFleetClient       │
│ (N tractors)  │  Kin/Op/Intent/Telem  │   (Python)           │
│               │  Video/Coverage       │   7 DataReaders      │
└───────────────┘                  ┌──► │                      │
┌───────────────┐  StationStatus   │    └──────────┬───────────┘
│ Charging Stn  │ ─────────────────┘               │ store.update_*()
│ (M stations)  │  (RELIABLE/TL)        ┌──────────▼───────────┐
└───────────────┘                       │  FleetStateStore     │
                                        │  (application state) │
                                        └────────┬─────────────┘
                                                 │ snapshot() every 200ms
                                     ┌───────────▼──────────┐
                                     │  SSE: /stream        │
                                     │  data: {state,       │
                                     │    kinematic,        │
                                     │    operational,      │
                                     │    intent, telemetry,│
                                     │    charging,         │
                                     │    coverage}         │
                                     └───────────┬──────────┘
                                                 │ EventSource
                                     ┌───────────▼──────────┐
                                     │  Browser JS          │
                                     │  updates tables +    │
                                     │  redraws canvas      │
                                     └──────────────────────┘
```

There are seven DDS DataReaders total, regardless of fleet size. One daemon
thread polls all seven sequentially and sleeps 50 ms after each complete or
failed cycle. Data from all matched tractors arrives through the same reader per
topic type, keyed by `tractor_id`; station samples are keyed by `station_id`.

The browser JS stashes:
- `lastIntentData` — not overwritten during drag.
- `lastChargingData` — for station icon rendering on map.
- `lastOperationalData` — cross-referenced by station icons and charging panel.
- `coverageData` — replaced from each SSE snapshot and rendered as map trails.

The `/stream` generator sleeps 0.2 seconds, so browser snapshots have a nominal
5 Hz cadence. It includes `state`, `kinematic`, `operational`, `intent`,
`telemetry`, `charging`, `coverage`, and `domain_id`.

---

## 9  Command Flow (Browser → Tractor)

```
Browser JS                     Flask /command             Tractor DDS
──────────                     ──────────────             ─────────
sendCommand(rid, cmd, extra)
  → POST /command {json}
                               → client.send_command()
                                 → build CommandRequest
                                 → requester.send_request()  → all tractors receive
                                 → requester.receive_replies()
                                 ← CommandResponse (from     ← target tractor responds
                                    matching tractor)
                               ← json {success, desc, …}
  ← update #cmd-result
```

For broadcast (`tractor_id == "ALL"`): one request reaches every tractor,
every tractor acts on it, and the UI collects the correlated replies (§4.2).

The persistent `Requester` serves repeated command operations. Each tractor's
`SimpleReplier` receives only the requests its content filter passes (its own
ID or `ALL`), so only addressed tractors execute and reply.

---

## 10  Resilience Behaviour

| Scenario | Behaviour |
|----------|-----------|
| Tractor stops sending positions | Marked `stale` (pulsing amber ring, "⚠ no update for N s") within about a second by the 500 ms `KinematicState` deadline |
| Tractor leaves | Marked `offline` when its instance becomes not alive (at once for an orderly shutdown, after the 30-second lease for a crash); removed 10 s later; its coverage trail stays |
| Tractor restarts | SPDP rematches it and its samples make it `live` again |
| Charging station disconnects | Last-known station state remains visible; no station pruning occurs |
| Command to unknown tractor | No tractor's filter passes it, so nothing replies; after five seconds the UI reports `{success: false, description: "Timeout waiting for <id>"}`. |
| Network blip | RELIABLE streams use DDS reliability subject to configured history/resource limits. BEST_EFFORT streams (kinematic, telemetry, video) may lose samples and resume with later writes. |
| Late-joining UI | Operational, intent, and station status use TRANSIENT_LOCAL last-value behavior; coverage uses PERSISTENT KEEP_LAST 1000; kinematic, telemetry, and video use VOLATILE behavior. |

Reliable and durable delivery follows configured QoS. The UI reacts to
`KinematicState` deadline misses and instance-state changes; it does not act
on deadline misses of other topics.

---

## 11  Thread Summary

| Thread | Daemon | Description |
|--------|--------|-------------|
| Main | No | Calls Flask `app.run(host="0.0.0.0", threaded=True)` |
| DDS reader polling | Yes | One explicitly created application thread calls all seven `take()` methods, then sleeps 50 ms |
| Flask handlers | Server-managed | Threaded request handling, including long-lived SSE and MJPEG generators |
| DDS internal | Middleware-managed | Discovery, receive, reliability, and RPC work |

There is no fixed total thread count because Flask adds handler threads and DDS
owns internal threads. Reader count and the one application polling thread stay
flat as fleet size grows. `/command` blocks its Flask handler while waiting for
replies, and the long-lived Requester has no application mutex around concurrent
HTTP commands.

### Shutdown

`main()` maps SIGTERM to the same path as Ctrl-C
(`signal.signal(signal.SIGTERM, signal.default_int_handler)`), so
`scripts/demo_stop.sh` and Ctrl-C both end `app.run()` and reach a `finally`
block that calls `DdsFleetClient.close()`. `close()`:

1. Sets `running = False`, which ends the poll, SSE, and MJPEG loops.
2. Joins the polling thread for up to one second.
3. Closes the command `Requester`. It owns an internal WaitSet, and the
   participant refuses to close while one is attached.
4. Closes the participant and calls
   `DomainParticipant.finalize_participant_factory()`.

Closing the participant deletes the video reader, so every tractor's video
writer unmatches and stops rendering; no explicit `deselect_video()` is
needed. `DdsFleetClient.stop()` remains available and only sets
`running = False`.

---

## 12  File Structure

The application is a **single Python file**
([`python/fleet_ui.py`](../fleet_ui.py)) that:

1. Imports DDS types from `fleet_types.py` (generated — never hand-edited).
2. Defines `FleetStateStore` (thread-safe application-state store).
3. Defines `DdsFleetClient` (DDS communication layer).
4. Defines `DASHBOARD_HTML` as a raw string containing the full HTML/CSS/JS.
5. Defines `create_app(store, client)` returning a Flask app.
6. Defines `main()` parsing CLI args, creating the store + client, and starting
   everything.

The HTML, CSS, and JavaScript are embedded in `fleet_ui.py`. The
`field1_map.jpg` static asset is served by the `/ground_texture.jpg` route.

### Companion files

| File | Purpose |
|------|---------|
| [`fleet_types.idl`](../../fleet_types.idl) | DDS IDL type definitions — single source of truth |
| [`python/fleet_types.py`](../fleet_types.py) | Auto-generated Python types |
| [`fleet_qos.xml`](../../fleet_qos.xml) | Pattern-based QoS profiles |
| [`python/tractor_node.py`](../tractor_node.py) | Tractor-side command, coverage, and video behavior |
| [`shared/field1_map.jpg`](../../shared/field1_map.jpg) | Map texture served by `/ground_texture.jpg` |

### External Dependencies

| Requirement | Imported API / use |
|-------------|--------------------|
| `rti.connext>=7.7.0` | Provides `rti.connextdds`, `rti.rpc`, and generated-type runtime support |
| `flask>=3.0.0` | Flask app, responses, templates, request parsing, JSON responses, and static-file serving |

`fleet_types` is the local generated module, not a separately installed
dependency. The repository requirements also include NumPy, Pillow, and
PyBullet for the tractor's video renderer; `fleet_ui.py` does not import them.

### Design Notes

| Concern | How DDS handles it |
|------------------|-----------------------------------|
| Discovery | SPDP discovers participants; SEDP discovers and matches endpoints |
| Tractor data reception | Six shared tractor-topic DataReaders polled by one daemon thread |
| Per-station data reception | `StationStatus` DataReader handles all stations |
| Presence display | Deadline status and instance states mark tractors stale or offline |
| Tractor identity | The `tractor_id` key in DDS samples and command requests |

---

## 13  DDS Type Contract Summary

The UI uses the following types from `fleet_types.py`:

### Types Read (via DataReaders)

| Type | Key | QoS Profile | Fields Used |
|------|-----|-------------|-------------|
| `KinematicState` | `tractor_id` | `KinematicStateProfile` | `tractor_id`, `position.x/y/z`, `velocity.x/y/z`, `heading` |
| `OperationalState` | `tractor_id` | `OperationalStateProfile` | `tractor_id`, `status` (enum), `battery_level` |
| `Intent` | `tractor_id` | `IntentProfile` | `tractor_id`, `intent_type`, DDS `target_position.x/y`, `path_waypoints[]`, `path_index` |
| `Telemetry` | `tractor_id` | `TelemetryProfile` | `tractor_id`, `cpu_usage`, `memory_usage`, `temperature`, `signal_strength` |
| `VideoFrame` (topic `LiveVideo`) | `tractor_id` | `VideoProfile` | `tractor_id`, `frame_data` (JPEG bytes) |
| `StationStatus` | `station_id` | `StationStatusProfile` | `station_id`, `dock_x/y`, `docked_tractor_id`, `queue[]`; `is_occupied` is ignored |
| `CoveragePoint` | `tractor_id` | `CoverageProfile` | `tractor_id`, `x`, `y` |
| `QueueEntry` | — | (nested) | `tractor_id`, `rank`, `confirmed` |

The effective reader QoS is loaded from `fleet_qos.xml`: kinematic uses
`Pattern.PeriodicData`; operational and station status use `Pattern.Status`;
intent uses `Pattern.LastValueCache`; telemetry and video use
`Pattern.Streaming`; and coverage overrides its `Pattern.Status` base to
PERSISTENT durability with KEEP_LAST depth 1000 and bounded resource limits.
The participant profile selects the fleet domain tag, `SPDP | SEDP`, and UDPv4.

### Types Written (via `rti.rpc.Requester`)

| Type | Key | Fields Written | Mechanism |
|------|-----|----------------|-----------|
| `CommandRequest` | — | `tractor_id`, `command`, optional typed `goto_params`, optional typed `set_path_params` | `command_requester.send_request()` |
| `GotoParameters` | — | `x`, `y`, `speed` | Nested in `CommandRequest` |
| `SetPathParameters` | — | `sequence<Waypoint>` | Nested in `CommandRequest` |

### Types Received (via `rti.rpc.Requester`)

| Type | Key | Fields Read | Mechanism |
|------|-----|-------------|-----------|
| `CommandResponse` | — | `tractor_id`, `success`, `description`, `resulting_status`, `resulting_intent` | `command_requester.receive_replies()` |

### Enums

- `TractorStatus`: `STATUS_UNKNOWN=0`, `STATUS_MOVING=1`, `STATUS_IDLE=2`, `STATUS_HOLDING=3`, `STATUS_CHARGING=4`
- `TractorIntentType`: `INTENT_UNKNOWN=0`, `INTENT_FOLLOW_PATH=1`, `INTENT_GOTO=2`, `INTENT_IDLE=3`, `INTENT_CHARGE_QUEUE=4`, `INTENT_CHARGE_DOCK=5`
- `Command`: `COMMAND_UNKNOWN=0`, `CMD_STOP=1`, `CMD_FOLLOW_PATH=2`, `CMD_GOTO=3`, `CMD_RESUME=4`, `CMD_SET_PATH=5`, `CMD_CHARGE=6`

---

## 14  Deployment

The UI is launched by `demo_start.sh` after the tractor nodes and charging stations:

```bash
# Start the dashboard
python fleet_ui.py --ui-port 5000 &
```

The browser connects to `http://localhost:5000`. The UI joins DDS domain 0 and
begins receiving data from matched tractor and station endpoints.
