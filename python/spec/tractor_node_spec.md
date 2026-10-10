# Tractor Fleet Node — Specification (RTI Connext DDS)

> This document fully specifies the `tractor_node.py` application so that an AI
> agent (or developer) can re-create it from scratch. It assumes the reader has
> access to the IDL type definitions (`fleet_types.idl`), the auto-generated
> Python types (`fleet_types.py`), the QoS profiles (`fleet_qos.xml`), and the
> companion renderer (`video_renderer.py`).

---

## 1  Purpose

A single tractor node that participates in a **peer-to-peer DDS fleet**. Every
node is a DDS DomainParticipant: it publishes its own state, intent, telemetry,
coverage, and matched-only onboard video; subscribes to peer and charging-station
state; handles operator commands through an `rti.rpc.SimpleReplier`; and reserves
or releases charging slots through `rti.rpc.Requester` objects.

Each node autonomously follows a waypoint route, records worked-area coverage,
avoids collisions with nearby peers, reacts to operator commands (STOP,
FOLLOW_PATH, GOTO, RESUME, SET_PATH, CHARGE), and manages an autonomous charging
workflow when battery is low. Charging-station choice and queue progression are
data-centric: the tractor selects from cached `StationStatus` samples and reacts
to listener callbacks rather than polling a request-reply service.

The node uses DDS discovery, liveliness, endpoint matching, partitions, sample
delivery, durability, and QoS policies for communication and lifecycle behavior.

**RPC pattern:** Commands use a `SimpleReplier` for
`CommandRequest → CommandResponse`. Charging uses two request-reply pairs:
`SlotReserve → SlotAssignment` and `SlotRelease → SlotReleaseAck`. The `rti.rpc`
API correlates requests and replies through DDS `SampleIdentity` metadata.

---

## 2  Technology Stack

| Layer | Technology |
|-------|------------|
| Language | Python 3.14.3+ |
| Middleware | RTI Connext DDS 7.7.0+ (`rti.connextdds`, `rti.rpc`) |
| Type generation | `rtiddsgen -language python fleet_types.idl` → `fleet_types.py` |
| QoS configuration | `fleet_qos.xml` — profiles based on `BuiltinQosLib::Pattern.*` |
| Concurrency | Python `threading` (daemon workers and `threading.Lock`) |
| CLI | `argparse` |
| Math and simulation | `math`, `random` |
| Video | `VideoRenderer`, PyBullet DIRECT mode, NumPy, Pillow, JPEG |
| Logging | `print()` with `[tractor_id HH:MM:SS]` prefix from `_ts()` |

Command parameters are typed objects defined in the `IDL`: `CommandRequest.goto_params` and
`CommandRequest.set_path_params` are optional IDL members.

### Technology Summary

| Concern | Approach |
|---------|----------|
| RPC framework | DDS-native request-reply through `rti.rpc` |
| Code generation | `rtiddsgen` produces `fleet_types.py` from the IDL |
| Discovery | DDS SPDP/SEDP on UDPv4, isolated by the configured domain ID and domain tag |
| Threading model | Seven long-lived application workers plus DDS internal threads |
| Selective video | Publisher partition and publication-match status |
| Persistent work history | `CoveragePoint` with persistent durability and bounded history |

---

## 3  Command-Line Interface

```text
python tractor_node.py --id NAME [--domain DOMAIN_ID]
```

| Argument | Type | Default | Description |
|----------|------|---------|-------------|
| `--id` | `str` (required) | — | Tractor ID, for example `tractor1` |
| `--domain` | `int` | `0` | DDS domain ID |

At startup `main()`:

1. Parses arguments.
2. Creates `TractorNode(args.id, args.domain)`.
3. Calls `run()`, which initializes DDS, starts workers, and blocks.

The participant name is the tractor ID and its role name is `Tractor`. The CLI
domain and the domain tag (default `tractor-fleet-salinas-CA`, configured in
the participant QoS from `fleet_qos.xml`) together determine which
participants may discover and match this node.

---

## 4  `TractorNode` Class — State & Attributes

### 4.1  Identity

| Attribute | Type | Description |
|-----------|------|-------------|
| `tractor_id` | `str` | Tractor name from `--id` |
| `domain_id` | `int` | DDS domain from `--domain` |
| `running` | `bool` | Master worker-loop flag |

### 4.2  Motion State

| Attribute | Type | Initial Value | Description |
|-----------|------|---------------|-------------|
| `position` | `dict {x,y,z}` | Random X/Y in 0–100; Z = 0 | Arena position |
| `status` | `TractorStatus` | `STATUS_MOVING` | Moving, idle, holding, or charging |
| `intent` | `TractorIntentType` | `INTENT_FOLLOW_PATH` | Current navigation/charging purpose |
| `battery_level` | `float` | `100.0` | Drains outside charging; refills at the dock |
| `goal` | `dict {x,y}` or `None` | `None` | GOTO, queue, or dock destination |
| `hold_position` | `dict {x,y}` or `None` | `None` | Spring-back point while holding |
| `speed` | `float` | `2.0` | Requested movement speed |
| `heading` | `float` | `0.0` | Current non-holonomic heading in radians |
| `velocity_x/y/z` | `float` | `0.0` | Last applied velocity; Z remains zero |
| `signal_strength` | `float` | `95.0` | Simulated link quality |
| `_pre_idle_status` | enum or `None` | `None` | Status saved by STOP and restored by RESUME |

### 4.3  Path and Coverage State

| Attribute | Type | Description |
|-----------|------|-------------|
| `path_waypoints` | `list[dict {x,y}]` | Random loop of 5–8 waypoints, generated at start (§5) |
| `path_index` | `int` | Current target waypoint index |
| `_path_version` | `int` | Incremented by SET_PATH so unchanged indices still republish |
| `_last_cov_x`, `_last_cov_y` | `float` | Last emitted coverage location; initialized to NaN |
| `_cov_working` | `bool` | True after path following reaches its first waypoint |

`path_target` returns `self.path_waypoints[self.path_index]`. Coverage is emitted
only while actively following a path after work has begun, and only after moving
at least one arena unit from the last coverage sample.

### 4.4  Charging State

| Attribute | Type | Description |
|-----------|------|-------------|
| `_station_docks` | `dict[str, dict]` | Cached dock coordinates, queue length, and occupied flag from `StationStatus` |
| `_charge_slot_id` | `str` or `None` | Unique station-issued queue token |
| `_charge_station_id` | `str` or `None` | Selected station ID |
| `_charge_dock` | `dict {x,y}` or `None` | Assigned dock coordinates |
| `_charge_wait_pos` | `dict {x,y}` or `None` | Locally calculated queue waiting position |
| `_charge_queue_rank` | `int` | Current rank; `-1` means not queued |
| `_charge_requested` | `bool` | Prevents concurrent charge attempts |
| `_pre_charge_intent/status/speed/goal/hold` | mixed | State saved before charging |
| `CHARGE_THRESHOLD` | `float` | `20.0` percent |
| `CHARGE_FULL` | `float` | `95.0` percent |
| `CHARGE_RATE` | `float` | `2.0` percent per second |

`_CHARGE_INTENTS` contains `INTENT_CHARGE_QUEUE` and `INTENT_CHARGE_DOCK`.

### 4.5  Peer Tracking

| Cache | Key | Value |
|-------|-----|-------|
| `other_tractors_state` | tractor ID | `KinematicState` |
| `other_tractors_operational` | tractor ID | `OperationalState` |
| `other_tractors_intent` | tractor ID | `Intent` |

`_nearby_peers` tracks IDs inside the avoidance region. `_fleet_tractor_ids`
tracks discovered peers for stable renderer color assignment.

### 4.6  Change Tracking

| Attribute | Purpose |
|-----------|---------|
| `_last_published_status`, `_last_published_battery` | OperationalState suppression |
| `_last_published_intent`, `_last_published_target` | Intent suppression |
| `_last_published_path_index`, `_last_published_path_version` | Path-change detection |

### 4.7  DDS, RPC, and Video Entities

| Attribute | Type | Description |
|-----------|------|-------------|
| `participant` | `dds.DomainParticipant` or `None` | Single tractor participant |
| `writers` | `dict[str, DataWriter]` | Six pub-sub writers |
| `readers` | `dict[str, DataReader]` | Four pub-sub readers |
| `command_replier` | `rpc.SimpleReplier` | `CommandRequest → CommandResponse` |
| `reserve_requester` | `rpc.Requester` | `SlotReserve → SlotAssignment` |
| `release_requester` | `rpc.Requester` | `SlotRelease → SlotReleaseAck` |
| `video_renderer` | `VideoRenderer` | Headless per-tractor 3-D renderer |

### 4.8  Locks

`data_lock` protects peer caches and station cache snapshots shared between DDS
callbacks, movement/avoidance, video rendering, and status reporting.

---

## 5  Path Route Generation

`_generate_path_route()` produces a random route when the tractor starts:

1. Choose a center with X and Y independently in `[20, 80]`.
2. Choose a radius in `[15, 30]`.
3. Choose 5–8 points.
4. Place points at evenly spaced angles with independent jitter in `[-5, 5]`.
5. Clamp every coordinate to `[5, 95]`.

The result is a roughly circular loop, different on every start, so the fleet
spreads out across the arena. Routes are not meant to be reproducible; any
random source will do. (The Python implementation seeds a private
`random.Random` from `hash(tractor_id)`, but Python randomizes string hashes
per process, so the route still changes on every start.) An operator can
replace the route at runtime with `CMD_SET_PATH`.

---

## 6  DDS Initialisation (`initialize_dds`)

One function creates the participant, topics, publishers/subscriber, six
writers, four readers, two requesters, the command replier, and listeners.

### 6.1  QoS Provider and Participant

1. Resolve `../fleet_qos.xml` relative to `tractor_node.py`.
2. Construct `dds.QosProvider(qos_xml)`.
3. Load `FleetQosLibrary::ParticipantProfile`.
4. Set participant name to `tractor_id` and role name to `Tractor`.
5. Create `dds.DomainParticipant(domain_id, participant_qos)`.

The profile selects UDPv4, SPDP/SEDP, endpoint-discovery optimizations, and the
fleet domain tag.

### 6.2  Topics (Seven Pub-Sub Topics)

| Topic | Type | Tractor Direction |
|-------|------|-------------------|
| `KinematicState` | `KinematicState` | Write + read |
| `OperationalState` | `OperationalState` | Write + read |
| `Intent` | `Intent` | Write + read |
| `Telemetry` | `Telemetry` | Write only |
| `LiveVideo` | `VideoFrame` | Write only |
| `CoveragePoint` | `CoveragePoint` | Write only |
| `StationStatus` | `StationStatus` | Read only |

RPC creates its own request/reply topics from each `service_name`; those are not
stored in this topic table.

### 6.3  Writers (Six)

| Key | Topic | QoS Profile | Publisher |
|-----|-------|-------------|-----------|
| `kinematic` | KinematicState | `KinematicStateProfile` | Common |
| `operational` | OperationalState | `OperationalStateProfile` | Common |
| `intent` | Intent | `IntentProfile` | Common |
| `telemetry` | Telemetry | `TelemetryProfile` | Common |
| `coverage` | CoveragePoint | `CoverageProfile` | Common |
| `video` | LiveVideo | `VideoProfile` | Dedicated, partition = tractor ID |

The video writer's dedicated Publisher has `partition.name = [tractor_id]`.
An unselected UI uses a nonmatching partition; selecting a tractor changes the
UI Subscriber partition to that ID, matching exactly that tractor's writer.

### 6.4  Readers (Four)

| Key | Topic | QoS Profile |
|-----|-------|-------------|
| `kinematic` | KinematicState | `KinematicStateProfile` |
| `operational` | OperationalState | `OperationalStateProfile` |
| `intent` | Intent | `IntentProfile` |
| `station` | StationStatus | `StationStatusProfile` |

### 6.5  Command `SimpleReplier`

```python
cmd_w_qos = qos_provider.datawriter_qos_from_profile(
    "FleetQosLibrary::CommandProfile")
cmd_r_qos = qos_provider.datareader_qos_from_profile(
    "FleetQosLibrary::CommandProfile")
cmd_request_topic = dds.Topic(
    self.participant, "TractorCommandRequest", CommandRequest)
cmd_filtered_topic = dds.ContentFilteredTopic(
    cmd_request_topic, f"TractorCommandRequest_{self.tractor_id}",
    dds.Filter("tractor_id = %0 OR tractor_id = %1",
               [f"'{self.tractor_id}'", f"'{ALL_TRACTORS}'"]))
self.command_replier = rpc.SimpleReplier(
    request_type=CommandRequest,
    reply_type=CommandResponse,
    participant=self.participant,
    service_name="TractorCommand",
    handler=self._handle_command,
    request_topic=cmd_filtered_topic,
    datawriter_qos=cmd_w_qos,
    datareader_qos=cmd_r_qos,
)
```

The replier reads `TractorCommandRequest`, the request topic `rti.rpc` names
after the service, through a content filter that passes only commands for
this tractor or for `ALL`. Connext evaluates the filter at the writer, so
commands for other tractors are never sent to this tractor.

The framework receives requests, invokes the handler, publishes its returned
response, and preserves DDS request/reply correlation.

### 6.6  Charging Requesters

Both requesters use the DataWriter and DataReader QoS of
`FleetQosLibrary::SlotNegotiationProfile` (`slot_w_qos`, `slot_r_qos`):

```python
self.reserve_requester = rpc.Requester(
    request_type=SlotReserve,
    reply_type=SlotAssignment,
    participant=self.participant,
    service_name="ChargingSlotReserve",
    datawriter_qos=slot_w_qos,
    datareader_qos=slot_r_qos,
)

self.release_requester = rpc.Requester(
    request_type=SlotRelease,
    reply_type=SlotReleaseAck,
    participant=self.participant,
    service_name="ChargingSlotRelease",
    datawriter_qos=slot_w_qos,
    datareader_qos=slot_r_qos,
)
```

`SlotReserve.station_id` directs the semantic request to the locally selected
station even though DDS request delivery may fan out to matched repliers. The
tractor accepts only a granted assignment whose `station_id` equals its choice.

### 6.7  QoS Behavior

| Data | Reliability / Durability | Notable Policy |
|------|--------------------------|----------------|
| KinematicState | Best effort / volatile | 10 Hz pattern; 30-second automatic liveliness lease |
| OperationalState | Reliable / transient local | Last status retained; 30-second liveliness |
| Intent | Reliable / transient local | Last intent retained; 30-second liveliness |
| Telemetry, LiveVideo | Best effort / volatile | Loss-tolerant streaming |
| CoveragePoint | Reliable / persistent | KEEP_LAST 1000, bounded resource limits |
| StationStatus | Reliable / transient local | Latest station state retained |
| Commands and slots | Reliable / volatile | `CommandProfile` and `SlotNegotiationProfile` (`Pattern.RPC`, keep-all), passed to each constructor |

---

## 7  DDS Listeners

`_setup_listeners()` attaches four nested `DataReaderListener` implementations.
Callbacks execute on DDS middleware threads; they do not create application
polling workers.

### 7.1  `KinematicListener`

`on_data_available()` takes all available samples, ignores the local tractor
ID, and stores each peer's newest `KinematicState` under `data_lock`. It also
records each valid sample's instance handle → `tractor_id`.

A sample without data whose instance state is not `ALIVE` means the peer's
writer is gone (`NOT_ALIVE_NO_WRITERS`): immediately after an orderly
shutdown, or once the liveliness lease expires after a crash. The listener
looks up the peer by instance handle and calls `_forget_peer()`, which removes
it from `other_tractors_state`, `other_tractors_operational`,
`other_tractors_intent`, and `_nearby_peers` under `data_lock` and logs
`Peer <id> gone — removed from avoidance`. Collision avoidance therefore stops
steering around a tractor that is no longer there. `_fleet_tractor_ids` keeps
the ID so renderer colors stay stable if the peer returns.

`on_liveliness_changed()` logs ALIVE/DEAD transitions. The endpoint QoS uses a
**30-second automatic liveliness lease**. The callback reports middleware
liveliness changes after lease expiry rather than providing an immediate crash
detector.

### 7.2  `OperationalListener`

Takes valid, non-self `OperationalState` samples and updates
`other_tractors_operational` under `data_lock`.

### 7.3  `IntentListener`

Takes valid, non-self `Intent` samples and updates `other_tractors_intent` under
`data_lock`.

### 7.4  `StationStatusListener`

For every valid sample:

1. Cache dock X/Y, `len(queue)`, and `is_occupied` by `station_id` under the lock.
2. If the sample belongs to this tractor's selected charging station and the
   tractor has a charging intent, call `_on_station_status_update()` outside the
   lock.

This listener is both the charging-state feed and the source of station geometry
for video. Queue rank changes are listener-driven; there is **no queue poller**.

### 7.5  Command Reception

No manual command reader listener exists. `SimpleReplier` receives the request,
calls `_handle_command(cmd)`, and sends the returned `CommandResponse`.

---

## 8  Command Handling (`_handle_command`)

A request is addressed to this tractor when its `tractor_id` is this
tractor's ID or the reserved value `ALL` (`ALL_TRACTORS`), which addresses
every tractor with one request. The request topic's content filter (§6.5)
normally keeps other tractors' commands from arriving; as a safeguard, a
request addressed to another tractor returns a successful no-op response with
description `not addressed to me`.
`main()` refuses `--id ALL`. Addressed commands behave as follows:

| Command | Effect |
|---------|--------|
| `CMD_STOP` | Save current status in `_pre_idle_status`; set `STATUS_IDLE`; zero X/Y velocity; leave intent, goal, hold position, and charging-slot ownership unchanged |
| `CMD_FOLLOW_PATH` | Abort an owned charge slot; clear goal/hold; set follow-path + moving; reset coverage; apply typed speed when positive |
| `CMD_GOTO` | Abort an owned charge slot; read typed X/Y/speed; set GOTO + moving |
| `CMD_RESUME` | Apply typed speed; preferentially restore `_pre_idle_status`, otherwise resume according to intent/goal/hold |
| `CMD_SET_PATH` | Read typed waypoint sequence; require at least two; replace route; preserve intent/status; increment `_path_version` |
| `CMD_CHARGE` | Reject if charging or already requested; otherwise spawn one `_initiate_charge` daemon invocation |
| Unknown | Return `success=False` |

### 8.1  Typed Parameters

```python
gp = cmd.goto_params
wps = cmd.set_path_params.waypoints if cmd.set_path_params is not None else []
```

`GotoParameters` supplies `x`, `y`, and `speed` for GOTO and optional speed for
FOLLOW_PATH/RESUME. `SetPathParameters` supplies the bounded waypoint sequence.
Missing GOTO parameters default X/Y to the current position and speed to zero.
There is no `parameters` string and no JSON decode fallback.

### 8.2  RESUME Detail

| Condition | Behavior |
|-----------|----------|
| `_pre_idle_status` exists | Restore exactly that status, then clear it |
| Follow-path intent | Clear hold and move |
| GOTO with goal | Clear hold and move |
| GOTO with hold but no goal | Copy hold to goal and move |
| GOTO with neither | Hold current position |
| Charge intent | Move if goal exists, hold if hold exists, otherwise move |
| Other | Hold current position |

### 8.3  Response Result

After mutation, the handler snapshots current status and intent into the response,
logs the description, and returns it to `SimpleReplier`.

---

## 9  Response Publishing

```python
return CommandResponse(
    tractor_id=self.tractor_id,
    success=success,
    description=description,
    resulting_status=self.status,
    resulting_intent=self.intent,
)
```

The application does not own a response writer and does not manually copy
request IDs. `SimpleReplier` publishes the returned object and correlates it to
the incoming request through DDS sample identity.

---

## 10  Movement Model (`update_position`)

The position worker runs with `dt = 0.1` seconds (10 Hz).

### 10.1  `STATUS_MOVING`

For GOTO and charging intents, compute a desired vector toward `goal`. If the
remaining distance is at most `speed × dt`, snap to the goal and:

- Dock intent → clear goal and enter `STATUS_CHARGING`.
- Queue intent → copy goal into `hold_position`, clear goal, and hold.
- Ordinary GOTO → copy goal into `hold_position`, clear goal, and hold.

For follow-path intent, steer toward `path_target`. On arrival, snap to it,
advance `path_index` with wraparound, set `_cov_working = True`, and immediately
calculate a vector toward the next waypoint.

Collision avoidance is combined with the desired vector, then
`_steer_heading()` applies a maximum turn rate of 2 radians/second. Large heading
errors reduce forward speed with a minimum turn factor of 0.2. Position and
velocity use this steered vector.

### 10.2  Coverage Emission

During active follow-path movement, coverage is written inline by the movement
worker when all conditions hold:

1. `_cov_working` is true (at least one waypoint has been reached).
2. `_charge_requested` is false.
3. Squared distance from the last coverage point is at least `1.0`.

The writer emits `CoveragePoint(tractor_id, x, y)`. NaN initial coordinates make
the first eligible comparison publish. Coverage resets on FOLLOW_PATH,
charge initiation, and charge-state clearing.

### 10.3  `STATUS_HOLDING`

A spring pulls toward `hold_position` when farther than 0.05 units, at
`min(0.5, distance)` speed. Avoidance is blended in, and the same turn-rate
limiter applies. Holding therefore permits small avoidance movements.

### 10.4  `STATUS_IDLE` and `STATUS_CHARGING`

IDLE has no movement branch. CHARGING zeros X/Y velocity and adds
`CHARGE_RATE × dt`, capped at 100. At `CHARGE_FULL`, it invokes
`_release_charge_slot()`.

### 10.5  Per-Tick Housekeeping

1. Clamp X/Y to `[0, 100]`.
2. Outside charging, subtract `0.01 + 0.01 × actual_speed` from battery.
3. Simulate signal strength from edge distance plus random ±3 jitter.
4. Below 20%, atomically mark a charge request and spawn `_initiate_charge()` if
   no request is active and status is not charging.
5. Sleep 0.1 seconds.

---

## 11  Collision Avoidance

### 11.1  Constants

| Name | Value | Meaning |
|------|-------|---------|
| `AVOIDANCE_RADIUS` | `12.0` | Normal influence radius |
| `AVOIDANCE_STRENGTH` | `4.0` | Base inverse-square strength |
| `MIN_SEPARATION` | `4.0` | Normal-operation hard override threshold |
| `MAX_TURN_RATE` | `2.0` | Heading change limit in radians/second |

### 11.2  `_compute_avoidance()`

1. Snapshot peer positions and, near a station, peer intents under `data_lock`.
2. Use 40% radius / 30% strength while docking, or 50% radius / 25% strength
   while queued near a station.
3. For each peer inside the effective radius, calculate
   `strength = effective_strength × (effective_radius / distance)²`.
4. Triple repulsion from a peer whose intent is `INTENT_CHARGE_DOCK` when this
   tractor is yielding near the station.
5. Set hard override below `MIN_SEPARATION` only in normal operation.
6. Log entry into the radius and clear only beyond 115% of the radius, providing
   hysteresis against log flicker.

The caller replaces goal velocity on a hard override and otherwise adds the
avoidance vector. `_steer_heading()` then converts that desired vector into
non-holonomic motion.

---

## 12  Publishing Threads

### 12.1  `publish_kinematic_state` — 10 Hz

Writes tractor ID, nested `Position`, nested `Velocity3`, and heading every
0.1 seconds with best-effort volatile QoS.

### 12.2  `publish_operational_state` — On Change, 10 Hz Check

At 10 Hz, compare status and battery rounded to one decimal place against the
last published values. Write only when either differs. Transient-local QoS gives
late joiners the latest state.

### 12.3  `publish_intent` — On Change, 10 Hz Check

At 10 Hz, derive the current target and write only when intent, rounded target,
path index, or path version changes. This check rate is **10 Hz**, not a periodic
1 Hz publish.

| Intent | `target_position` | Waypoints |
|--------|-------------------|-----------|
| GOTO | goal, else hold, else current position | Empty |
| Charge queue/dock | assigned dock, else goal, else current position | Empty |
| Follow path | current path target | Full current route |
| Other | current position | Empty |

### 12.4  `publish_telemetry` — 1 Hz

Writes simulated CPU usage (20–80), memory usage (30–70), temperature (40–70),
and the current simulated signal strength. These are sample fields, not claims
of process or host instrumentation.

### 12.5  Coverage — Movement-Driven

Coverage has no dedicated worker. `update_position()` writes distance-filtered
`CoveragePoint` samples as specified in §10.2.

### 12.6  `publish_video` — Matched Only, Approximately 5 fps

`_is_video_requested()` reads
`writers['video'].publication_matched_status.current_count`. With no matches, the
worker sleeps 0.2 seconds and performs no rendering. With a match, it snapshots
peer states, statuses, heading, waypoints, and station docks under the lock;
renders a 400×300 JPEG through `VideoRenderer`; and writes it as a `VideoFrame`
sample on `LiveVideo`.

The writer resides on a Publisher whose partition is the tractor ID. Therefore
only a UI Subscriber selecting that partition matches it. Unselected tractors
see zero current matches and avoid PyBullet rendering cost. The mechanism uses
partition matching, not a content-filtered topic or application polling protocol.

`VideoRenderer` serializes rendering with an internal lock and uses a headless
PyBullet DIRECT client with `ER_TINY_RENDERER`. NumPy and Pillow convert the
RGBA result into a 400×300 quality-80 JPEG and overlay labels for peers,
waypoints, and charging stations.

---

## 13  Charging Workflow

Charging starts from `CMD_CHARGE` or the low-battery trigger. `_charge_requested`
prevents overlapping attempts.

### 13.1  Local Station Selection

`_initiate_charge()` stashes navigation state and stops coverage. It scans the
`_station_docks` cache populated by `StationStatusListener`, ranking stations by:

1. Shortest current queue (`queue_len`).
2. Shortest Euclidean distance as the tie-breaker.

If no station status is known, the tractor logs the condition, clears the request
flag, and remains on its task. There is no request-reply offer-discovery phase.

### 13.2  `SlotReserve → SlotAssignment`

The tractor sends one typed request naming the chosen station:

```python
request_id = self.reserve_requester.send_request(SlotReserve(
    tractor_id=self.tractor_id,
    station_id=best_sid,
    battery_level=self.battery_level,
))
replies = self.reserve_requester.receive_replies(
    dds.Duration.from_seconds(5), related_request_id=request_id)
```

A timeout becomes an empty reply list. The tractor accepts the first valid,
granted `SlotAssignment` from `best_sid`. If intent changed while waiting, it
sends a release for the newly assigned slot and abandons the charge transition.

### 13.3  Assignment Navigation

Store slot ID, station ID, dock coordinates, and queue rank. Rank zero sets the
dock as goal and uses `INTENT_CHARGE_DOCK`. A positive rank calls
`_wait_position(dock_x, dock_y, rank)`, which places tractors eight units apart
along the station-to-arena-center axis, then uses `INTENT_CHARGE_QUEUE`.

In both cases status becomes moving, hold is cleared, and speed becomes 3.0.

### 13.4  Listener-Driven Queue Advancement

`_on_station_status_update()` searches the selected station's published queue
for this tractor:

- Rank becomes zero → navigate to `_charge_dock` with dock intent.
- Positive rank changes → recompute the wait position and navigate there.
- Tractor disappears while queued → `_abort_charge()` clears the saved charge
   state before the callback's restoration statements run, so the current
   implementation falls back to moving `INTENT_FOLLOW_PATH` at speed `2.0`
   with no goal.

Rank updates arrive exclusively through `StationStatusListener`; no periodic
confirmation request or queue-polling worker exists.

### 13.5  Docking, Charging, and Release

Dock arrival enters `STATUS_CHARGING`. The movement worker fills battery at 2%
per second until 95%, then `_release_charge_slot()` sends `SlotRelease` with
tractor, slot, and station IDs. Release is fire-and-forget so the movement worker
does not block waiting for `SlotReleaseAck`.

After sending, the tractor resumes stashed work. An arrived GOTO is reissued
toward its former hold point; otherwise intent and speed are restored, status is
set moving, and the saved goal is restored. `_clear_charge_state()` then clears
all charging fields and coverage progress.

### 13.6  Operator Abort

FOLLOW_PATH or GOTO aborts when a slot is owned. `_abort_charge()` sends the same
typed `SlotRelease` without waiting for an acknowledgement, logs failures, and
clears charge state. The command handler then establishes the new task.

---

## 14  Status Reporting (`print_status`)

The status worker wakes every five seconds but suppresses repetitive output. It
prints immediately when status or intent differs from the previous printed
values, otherwise prints a heartbeat after six checks (approximately 30 seconds).

```text
[tractor_id HH:MM:SS] pos=(x,y) STATUS/INTENT batt=N% sig=N% peers=P
```

| Token | Source |
|-------|--------|
| `pos` | Current X/Y rounded to one decimal |
| `STATUS/INTENT` | Enum `.name` values |
| `batt` | Simulated battery rounded to an integer |
| `sig` | Simulated signal strength rounded to an integer |
| `peers` | Size of the kinematic peer cache under `data_lock` |

No additional latency, throughput, CPU, memory, or packet-loss metric is
calculated by this reporting worker.

---

## 15  Main Run Loop

`run()`:

1. Calls `initialize_dds()`.
2. Sets `running = True`.
3. Creates and starts seven named daemon workers:
   - `position` → `update_position`
   - `kinematic` → `publish_kinematic_state`
   - `operational` → `publish_operational_state`
   - `intent` → `publish_intent`
   - `telemetry` → `publish_telemetry`
   - `video` → `publish_video`
   - `status` → `print_status`
4. Blocks in a one-second main-thread sleep loop.
5. On shutdown, clears `running`, joins each worker for up to one second,
   disconnects the PyBullet renderer (`VideoRenderer.close()`), closes the
   command `SimpleReplier` and both charging `Requester`s, closes the
   participant, and calls `DomainParticipant.finalize_participant_factory()`.
   The RPC objects must be closed first: each owns an internal WaitSet, and
   the participant refuses to close while one is attached. This cleanup also
   runs if DDS initialization or the main loop raises an exception.

Charge initiation is a one-shot daemon thread created on demand; it is not one
of the seven long-lived workers.

`main()` maps SIGTERM to the same path as Ctrl-C
(`signal.signal(signal.SIGTERM, signal.default_int_handler)`), so
`scripts/demo_stop.sh`, which sends SIGTERM, produces the same clean shutdown.

---

## 16  Resilience Behaviour

| Scenario | Behavior |
|----------|----------|
| Peer starts late or rejoins | SPDP/SEDP discovers and matches it; transient-local state is delivered by matching writers |
| Peer leaves or loses liveliness | Its `KinematicState` instance becomes not alive (at once for an orderly shutdown, after the 30-second lease for a crash); the peer is removed from the avoidance caches (§7.1) |
| Best-effort sample loss | Kinematic/video/telemetry tolerate loss; later periodic samples supersede it |
| Reliable sample loss | DDS reliability repairs OperationalState, Intent, StationStatus, coverage, and RPC traffic subject to QoS/resource limits |
| No known charging station | Charge attempt ends without changing the current task |
| Reserve timeout or denial | Five-second receive timeout/absence of a valid assignment clears the request flag |
| Command arrives during reserve | Post-reply intent guard releases the newly granted slot instead of overriding the command |
| Queue changes | StationStatus callback updates rank and navigation without polling |
| Video UI deselects tractor | Partition unmatches; current match count reaches zero; rendering pauses |
| Ctrl-C, SIGTERM, or run-loop failure | Workers observe `running=False`; the renderer disconnects, RPC objects close, and participant closure disposes DDS entities before the factory is finalized |

With persistent `CoveragePoint` durability, the tractor's writer delivers its
retained history to late joiners. RTI Persistence Service, when running (it is
optional), also stores and replays it across tractor restarts. The tractor
itself does not implement a local persistence database.

---

## 17  Thread Summary

| Thread | Daemon | Lifetime / Responsibility | Created By |
|--------|--------|---------------------------|------------|
| Main | No | Owns `run()` and shutdown | `main()` |
| `position` | Yes | 10 Hz movement, charging, coverage | `run()` |
| `kinematic` | Yes | 10 Hz kinematic writer | `run()` |
| `operational` | Yes | On-change writer, checked at 10 Hz | `run()` |
| `intent` | Yes | On-change writer, checked at 10 Hz | `run()` |
| `telemetry` | Yes | 1 Hz telemetry writer | `run()` |
| `video` | Yes | Match check and approximately 5 fps rendering when selected | `run()` |
| `status` | Yes | Five-second checks, change/30-second heartbeat logging | `run()` |
| Charge initiator | Yes | One reserve transaction; exits after success/failure | Command or low-battery trigger |
| DDS internal threads | Managed | Discovery, receive, listener, RPC, reliability work | `DomainParticipant` / middleware |

There are exactly **seven long-lived application worker threads**, including
video. DDS listener callbacks run on middleware-managed threads. There is no
long-lived charging queue poller and no per-peer application thread.

---

## 18  Type Contract Summary

Types come from `fleet_types.py`, generated from `fleet_types.idl`.

### 18.1  Enums

- `TractorStatus`: UNKNOWN, MOVING, IDLE, HOLDING, CHARGING (values 0–4).
- `TractorIntentType`: UNKNOWN, FOLLOW_PATH, GOTO, IDLE, CHARGE_QUEUE,
  CHARGE_DOCK (values 0–5).
- `Command`: UNKNOWN, STOP, FOLLOW_PATH, GOTO, RESUME, SET_PATH, CHARGE
  (values 0–6).

### 18.2  Pub-Sub Types Used by the Tractor

| Type | Key | Fields Relevant Here | Direction |
|------|-----|----------------------|-----------|
| `KinematicState` | `tractor_id` | `position`, `velocity`, `heading` | Write + read |
| `OperationalState` | `tractor_id` | `status`, `battery_level` | Write + read |
| `Intent` | `tractor_id` | `intent_type`, `target_position`, `path_waypoints`, `path_index` | Write + read |
| `Telemetry` | `tractor_id` | CPU, memory, temperature, signal strength | Write |
| `VideoFrame` (topic `LiveVideo`) | `tractor_id` | Bounded JPEG `frame_data` sequence | Write |
| `CoveragePoint` | `tractor_id` | `x`, `y` | Write |
| `StationStatus` | `station_id` | Dock, occupancy, docked tractor, queue | Read |

Helper structs are `Position`, `Velocity3`, `Waypoint`, and `QueueEntry`.

### 18.3  Command Types

| Type | Fields |
|------|--------|
| `GotoParameters` | `x`, `y`, `speed` |
| `SetPathParameters` | Bounded `waypoints` sequence |
| `CommandRequest` | `tractor_id`, `command`, optional `goto_params`, optional `set_path_params` |
| `CommandResponse` | `tractor_id`, `success`, `description`, resulting status and intent |

The optional typed members are the active contract. No JSON field exists.

### 18.4  Charging Types

| Request → Reply | Request Fields | Reply Fields |
|-----------------|----------------|--------------|
| `SlotReserve → SlotAssignment` | tractor ID, station ID, battery level | station ID, slot ID, granted, queue rank, dock X/Y |
| `SlotRelease → SlotReleaseAck` | tractor ID, slot ID, station ID | station ID, slot ID, success |

The current contract has no separate offer/confirmation exchange. Queue state is
represented by `StationStatus.queue`.

### 18.5  Contract Properties

| Aspect | Contract |
|--------|----------|
| Timestamp | DDS `SampleInfo` metadata; no application timestamp field |
| Correlation | `rti.rpc` uses `SampleIdentity` |
| Command parameters | Optional typed IDL structs |
| Station selection | Local decision from transient-local StationStatus data |
| Coverage retention | Persistent DDS durability with bounded KEEP_LAST history |

---

## 19  File Structure

`tractor_node.py` contains:

1. Imports and generated type references.
2. `_CHARGE_INTENTS` and `_ts()`.
3. `TractorNode` state initialization.
4. Random path generation.
5. DDS entity creation and four listeners.
6. Typed command handling and returned responses.
7. Local station selection, reserve, listener-driven queue updates, release,
   and charge-state helpers.
8. Collision avoidance and non-holonomic steering.
9. Movement, coverage, state, telemetry, video, and status workers.
10. `run()` and the CLI `main()` entry point.

### Companion Files

| File | Purpose |
|------|---------|
| `fleet_types.idl` | Authoritative DDS type contract |
| `fleet_types.py` | Generated Python type support; never hand-edit |
| `fleet_qos.xml` | Participant and endpoint QoS profiles |
| `video_renderer.py` | Headless PyBullet scene, camera, labels, and JPEG encoder |
| `charging_station.py` | Publishes StationStatus and serves reserve/release RPC |
| `fleet_ui.py` | Fleet visualization, commands, coverage, and partition-selected video |
| `shared/arena_ground.urdf` | Required textured ground-plane geometry for `VideoRenderer` |
| `shared/field1_texture.jpg` | Optional ground texture; renderer uses a plain floor when absent |

### External Dependencies

| Package | Use |
|---------|-----|
| `rti.connextdds` | Participants, topics, endpoints, listeners, QoS, durations |
| `rti.rpc` | `SimpleReplier` and charging `Requester` objects |
| `pybullet` | Headless 3-D scene and camera rendering |
| `numpy` | Projection/math support in the renderer |
| `Pillow` | JPEG encoding and 2-D text overlays |

The implementation remains centered on one `TractorNode`, while rendering is
encapsulated in `VideoRenderer` and wire contracts remain generated from IDL.

---

## 20  Acceptance Checks

A tractor node implementation conforms to this specification when:

1. It starts with a required tractor ID and an optional domain, the
   participant has the tractor ID as its name and `Tractor` as its role, and
   the startup log reports seven worker threads.
2. It creates six pub-sub writers, four pub-sub readers, one command
   `SimpleReplier`, and two charging `Requester`s, each with its named QoS
   profile and service (§6).
3. Each typed command returns the response fields in §8.3 and has the
   status, intent, route, goal, speed, and reservation effects in §8, whether
   addressed to the tractor's ID or to `ALL`; `--id ALL` is refused.
4. Given several stations' `StationStatus`, it selects the shortest queue
   (nearest on ties), sends directed reserve and release requests with the
   fields in §13, follows queue-rank changes, is promoted to the dock,
   charges to 95%, and restores the saved task.
5. `KinematicState` is published at 10 Hz and `Telemetry` at 1 Hz,
   `OperationalState` and `Intent` only on change, and `CoveragePoint` only
   after the first reached waypoint, at least one arena unit apart.
6. Matching and unmatching the tractor-ID video partition starts and stops
   rendering; valid 400×300 JPEG frames appear only while matched.
7. Bringing a peer writer up and removing it produces liveliness
   transitions governed by the configured 30-second lease (no sub-second
   guarantee), and a departed peer is removed from the avoidance caches: at
   once after an orderly shutdown, after the lease after a crash.
8. Interrupting (Ctrl-C) or terminating (SIGTERM) the process stops the
   workers, closes the RPC objects and the DDS participant without errors,
   and finalizes the participant factory.
