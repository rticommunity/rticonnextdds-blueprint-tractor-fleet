# Charging Station Specification

This document fully specifies the `charging_station.py` application so that an
AI agent (or developer) can re-create it from scratch. It assumes the reader has
access to the IDL type definitions (`fleet_types.idl`), the auto-generated Python
types (`fleet_types.py`), and the QoS profiles (`fleet_qos.xml`).

---

## 1  Purpose

A standalone DDS participant that manages a **single charging dock** for the
tractor fleet. Only one tractor can charge at a time; additional tractors queue
in FIFO order and wait near the station until the dock becomes free.

The charging station is a separate process from the tractor nodes. Multiple
stations can run simultaneously, such as one at each corner of the arena, to
provide additional charging capacity.

The station is a DDS DomainParticipant. Tractors discover it through SPDP and
match its request-reply endpoints through SEDP. Slot negotiation uses two
callback-driven `rti.rpc.SimpleReplier` objects:

- `SlotReserve → SlotAssignment`
- `SlotRelease → SlotReleaseAck`

The station also publishes its current dock and queue state on the
`StationStatus` topic for tractors and fleet UIs.

**RPC pattern:** All stations use the same service names. A `SlotReserve`
contains the selected `station_id`; the selected station reserves a slot while
other stations return `granted=false` without modifying their queues. Tractors
select a station beforehand from published `StationStatus` data.

---

## 2  Technology Stack

| Layer | Technology |
|-------|-----------|
| Language | Python 3.14.3+ |
| Middleware | RTI Connext DDS 7.7.0+ (`rti.connextdds`, `rti.rpc`) |
| Type generation | `rtiddsgen -language python fleet_types.idl` → `fleet_types.py` |
| QoS configuration | `fleet_qos.xml` — Pattern-based profiles (`BuiltinQosLib::Pattern.*`) |
| Concurrency | `threading.Lock`; RPC callbacks execute on DDS internal threads |
| CLI | `argparse` |
| Data structures | `collections.OrderedDict` (preserves FIFO insertion order) |
| IDs | `uuid.uuid4()` truncated to 8 characters for slot IDs |
| Logging | `print()` with `[station_id HH:MM:SS]` prefix via `_ts()` |

Runtime dependencies are the Python standard library and RTI Connext Python
APIs.

### Technology Summary

| Concern | Approach |
|---------|----------|
| RPC framework | Two `rti.rpc.SimpleReplier` objects with callback handlers |
| Discovery | DDS SPDP participant discovery and SEDP endpoint discovery |
| Threading model | Main application thread plus DDS internal callback threads |
| Status streaming | DDS `StationStatus` topic (`RELIABLE / TRANSIENT_LOCAL`) |
| Late joiners | `TRANSIENT_LOCAL` supplies the latest station status from a live writer |
| Code generation | `rtiddsgen` generates `fleet_types.py` |

---

## 3  Command-Line Interface

```text
python charging_station.py --id ID [--domain DOMAIN_ID] [--dock-x X] [--dock-y Y]
```

| Argument | Type | Default | Description |
|----------|------|---------|-------------|
| `--id` | str (required) | — | Station identifier, such as `station1` |
| `--domain` | int | `0` | DDS domain ID; must match tractors and fleet UIs |
| `--dock-x` | float | `50.0` | Dock X coordinate in the arena |
| `--dock-y` | float | `5.0` | Dock Y coordinate in the arena |

At startup `main()`:

1. Parses arguments.
2. Maps SIGTERM to the same path as Ctrl-C
   (`signal.signal(signal.SIGTERM, signal.default_int_handler)`), so
   `scripts/demo_stop.sh` produces a clean shutdown.
3. Creates `ChargingStation(station_id, domain_id, dock_x, dock_y)`.
4. Calls `run()`, which initializes DDS, publishes initial status, and blocks.
   On Ctrl-C, SIGTERM, or a startup failure, its `finally` block calls
   `shutdown()`, which closes both `SimpleReplier`s, then the participant, and
   then calls `DomainParticipant.finalize_participant_factory()`.

The participant name is the station ID and the participant role name is
`ChargingStation`. `FleetQosLibrary::ParticipantProfile` supplies the domain
tag, SPDP/SEDP discovery configuration, and UDPv4 transport selection.

---

## 4  `ChargingStation` Class — State

### 4.1  Identity

| Attribute | Type | Description |
|-----------|------|-------------|
| `station_id` | `str` | Station name from `--id` |
| `domain_id` | `int` | DDS domain from `--domain` |
| `dock_x` | `float` | Dock X coordinate |
| `dock_y` | `float` | Dock Y coordinate |
| `running` | `bool` | Main-loop flag; initialized to `False` |

### 4.2  Queue State (protected by `self.lock`)

| Attribute | Type | Description |
|-----------|------|-------------|
| `_queue` | `OrderedDict[str, dict]` | `slot_id → {"tractor_id": str, "ts": float}`; insertion order determines rank |
| `_charging` | `str` or `None` | Slot ID currently assigned to the dock; `None` when free |
| `lock` | `threading.Lock` | Guards `_queue` and `_charging` |

### 4.3  DDS Entities

| Attribute | Type | Description |
|-----------|------|-------------|
| `participant` | `dds.DomainParticipant` or `None` | Single DDS participant for this station |
| `writers` | `dict[str, dds.DataWriter]` | Contains the `station_status` writer |
| `tractor_reader` | `dds.DataReader[OperationalState]` or `None` | Tractor presence; frees slots of departed tractors (§12) |
| `_tractor_handles` | `dict[InstanceHandle, str]` | `OperationalState` instance handle → `tractor_id` |
| `reserve_replier` | `rti.rpc.SimpleReplier` or `None` | Receives `SlotReserve`, returns `SlotAssignment` |
| `release_replier` | `rti.rpc.SimpleReplier` or `None` | Receives `SlotRelease`, returns `SlotReleaseAck` |

### 4.4  Constants

| Name | Value | Description |
|------|-------|-------------|
| `CHARGE_DURATION_ESTIMATE` | `45` s | Present in the implementation but currently unused |

There is no stale-offer timeout, reservation timer, or periodic status
interval; departed tractors are detected through DDS (§12).

---

## 5  Queue Model

The queue is an `OrderedDict` where:

- **Keys** are `slot_id` strings derived from the first eight characters of a
  UUID string.
- **Values** are dictionaries containing `tractor_id` and reservation `ts`.
- **Insertion order** determines rank: the first entry is rank `0`, the second
  rank `1`, and so on.

A slot moves through these states:

1. **Reserved**: An accepted `SlotReserve` immediately inserts the tractor in
   the queue. There is no separate offer or confirmation phase.
2. **Docking/charging**: If the new slot is rank `0` and the dock is free,
   `_charging` is set to that slot ID.
3. **Waiting**: Positive ranks remain in FIFO order and observe position
   changes through `StationStatus`.
4. **Released**: `SlotRelease` removes the entry, or the station removes it
   when the tractor's `OperationalState` writer goes away (§12). If it
   occupied the dock, the first remaining entry is promoted.

All published `QueueEntry` values set `confirmed=true` because reservation is
immediate. The station does not validate that a releasing `tractor_id` owns the
specified `slot_id`.

---

## 6  DDS Initialisation

### 6.1  QoS Provider

1. Resolve `fleet_qos.xml` one directory above the Python script.
2. Create `dds.QosProvider(qos_xml)`.
3. Load `FleetQosLibrary::ParticipantProfile`.

### 6.2  Participant and Infrastructure

1. Set the participant name to `station_id` and role name to
   `ChargingStation`.
2. Create `dds.DomainParticipant(domain_id, participant_qos)`.
3. Create one `dds.Publisher` for `StationStatus`.
4. Create one `dds.Subscriber` for the `OperationalState` presence reader.

### 6.3  Topics (pub-sub only)

| Topic Name | Type | Direction | QoS Profile |
|------------|------|-----------|-------------|
| `StationStatus` | `StationStatus` | Write | `FleetQosLibrary::StationStatusProfile` |
| `OperationalState` | `OperationalState` | Read (presence only) | `FleetQosLibrary::OperationalStateProfile` |

The `rti.rpc.SimpleReplier` objects create the internal request and reply DDS
entities required by each service.

### 6.4  Pub-Sub Writers (1 total)

| Dict Key | Topic | QoS Profile |
|----------|-------|-------------|
| `station_status` | `StationStatus` | `FleetQosLibrary::StationStatusProfile` |

The station also creates one `OperationalState` DataReader
(`tractor_reader`, `FleetQosLibrary::OperationalStateProfile`) with a
`DATA_AVAILABLE` listener. It does not use the tractors' operational data; it
uses the instance states to detect tractors that leave (§12).

### 6.5  RPC Objects — Slot Negotiation Repliers

Two `SimpleReplier` objects are created. Their service names must match the
corresponding Requesters in `tractor_node.py`. Both use the DataWriter and
DataReader QoS of `FleetQosLibrary::SlotNegotiationProfile` (`Pattern.RPC`:
reliable, keep-all), as the tractor's Requesters do:

```python
slot_w_qos = qos_provider.datawriter_qos_from_profile(
    "FleetQosLibrary::SlotNegotiationProfile")
slot_r_qos = qos_provider.datareader_qos_from_profile(
    "FleetQosLibrary::SlotNegotiationProfile")

self.reserve_replier = rpc.SimpleReplier(
    request_type=SlotReserve,
    reply_type=SlotAssignment,
    participant=self.participant,
    service_name="ChargingSlotReserve",
    handler=self._on_slot_reserve,
    datawriter_qos=slot_w_qos,
    datareader_qos=slot_r_qos,
)

self.release_replier = rpc.SimpleReplier(
    request_type=SlotRelease,
    reply_type=SlotReleaseAck,
    participant=self.participant,
    service_name="ChargingSlotRelease",
    handler=self._on_slot_release,
    datawriter_qos=slot_w_qos,
    datareader_qos=slot_r_qos,
)
```

`rti.rpc` correlates replies to requests through DDS `SampleIdentity`; the IDL
structures do not contain a `request_id` field.

### 6.6  Request Callback Dispatch

`SimpleReplier` invokes callbacks on DDS internal threads. No application
receive loop or request-processing thread is created.

- `_on_slot_reserve(request)` calls `_handle_slot_reserve(request)`, publishes
  `StationStatus`, and returns the `SlotAssignment`.
- `_on_slot_release(request)` calls `_handle_slot_release(request)`, publishes
  `StationStatus`, and returns the `SlotReleaseAck`.

Because status publication occurs before the callback returns, an uncaught DDS
write exception can prevent that callback invocation from returning its reply.

---

## 7  Slot Reserve Handling (`_handle_slot_reserve`)

Called by `_on_slot_reserve()` when a tractor sends `SlotReserve`. The request
contains `tractor_id`, selected `station_id`, and informational
`battery_level`.

1. Acquire `self.lock`.
2. Apply station targeting:
   - Empty `station_id` is accepted.
   - This station's ID is accepted.
   - Any other non-empty ID returns `granted=false`, `slot_id=""`, and
     `queue_rank=-1` without modifying the queue.
3. Generate `slot_id = str(uuid.uuid4())[:8]`.
4. Capture `queue_rank = len(_queue)` and append
   `{tractor_id: request.tractor_id, ts: time.time()}`.
5. If rank is `0` and `_charging is None`, assign the new slot to `_charging`.
6. Return:

   ```python
   SlotAssignment(
       station_id=self.station_id,
       slot_id=slot_id,
       granted=True,
       queue_rank=queue_rank,
       dock_x=self.dock_x,
       dock_y=self.dock_y,
   )
   ```

7. `_on_slot_reserve()` publishes the resulting `StationStatus` and returns
   the assignment.

`battery_level` affects only the log message for a waiting reservation. The
station does not calculate or return a wait-time estimate.

---

## 8  Queue Rank Updates

There is no `SlotConfirm` service and no station-side rank polling operation.
Queue progress is published through `StationStatus` after each reserve or
release callback.

The tractor consumes rank as follows:

1. Initial assignment rank `0` directs it to the dock.
2. A positive rank directs it to a computed waiting position.
3. While in a charging intent, it finds its first matching `tractor_id` in
   `StationStatus.queue`.
4. A change from a positive rank to `0` directs it to the dock.
5. A changed positive rank recomputes its waiting position.
6. Absence from the selected station's queue aborts charging and causes the
   tractor to send a release without waiting for its acknowledgement.

Rank tracking therefore uses pub-sub state rather than repeated request-reply
calls.

---

## 9  Slot Release Handling (`_handle_slot_release`)

Called by `_on_slot_release()` when a tractor completes or cancels charging.

1. Acquire `self.lock`.
2. If a non-empty `station_id` identifies another station, return success
   without changing local state.
3. Look up `request.slot_id`.
   - If absent, return success unchanged. This makes unknown and repeated
     releases idempotent.
4. Remove a present slot from `_queue`.
5. If `_charging == request.slot_id`:
   - Set `_charging = None`.
   - Call `_advance_queue()` to promote the first remaining slot.
6. Return:

   ```python
   SlotReleaseAck(
       station_id=self.station_id,
       slot_id=request.slot_id,
       success=True,
   )
   ```

7. `_on_slot_release()` publishes the resulting `StationStatus` and returns
   the acknowledgement.

Removing a waiting slot compacts later ranks while leaving the dock occupant
unchanged. The handler uses `slot_id` as authority and does not compare
`request.tractor_id` with the stored tractor ID.

---

## 10  StationStatus Publishing

The station publishes its current state:

- once after successful DDS initialization; and
- once after every reserve or release callback, including foreign-target,
  unknown-slot, and repeated requests that do not mutate local state.

There is no periodic `StationStatus` heartbeat thread. The profile
`StationStatusProfile` inherits from `Pattern.Status`:

- `RELIABLE` delivery;
- `TRANSIENT_LOCAL` durability; and
- `KEEP_LAST depth=1` history.

A late-joining reader can therefore receive the latest keyed status while the
station writer remains available.

### StationStatus Sample

```python
StationStatus(
    station_id=self.station_id,
    dock_x=self.dock_x,
    dock_y=self.dock_y,
    is_occupied=(self._charging is not None),
    docked_tractor_id=docked_tractor,  # "" if free
    queue=[
        QueueEntry(
            tractor_id=entry["tractor_id"],
            rank=rank,
            confirmed=True,
        )
        for rank, (slot_id, entry) in enumerate(self._queue.items())
    ],
)
```

Status construction occurs under `self.lock`; the completed sample is written
after releasing the lock. If `_charging` references a missing queue entry,
status construction logs the inconsistency and clears `_charging` before
creating the sample.

---

## 11  Queue Waiting Positions

Waiting positions are computed by `tractor_node.py`, not by the charging
station. The station supplies `dock_x`, `dock_y`, and `queue_rank`.

**Algorithm:** Tractors line up from the dock toward the arena center `(50,50)`.
Only positive ranks wait; rank `0` uses the dock itself.

1. `spacing = 8` arena units.
2. `offset = 10 + rank × spacing`.
3. `dx = 1 if dock_x < 50 else -1` and
   `dy = 1 if dock_y < 50 else -1`.
4. If `|50 - dock_x| ≥ |50 - dock_y|`, queue along X at
   `(dock_x + dx × offset, dock_y)`.
5. Otherwise queue along Y at `(dock_x, dock_y + dy × offset)`.

**Examples:**

- Station `(8,92)`: rank `1` waits at `(26,92)`, rank `2` at `(34,92)`.
- Station `(92,8)`: rank `1` waits at `(74,8)`, rank `2` at `(66,8)`.

---

## 12  Reservation Lifetime

Reservations have no timer; the stored timestamp is not used by a cleanup
routine. A slot remains until:

- a matching `SlotRelease` removes it;
- the tractor that holds it leaves the system; or
- the station process exits and loses its in-memory queue.

**Departed tractors.** The `OperationalState` reader's listener records each
valid sample's instance handle → `tractor_id`. When a sample without data
arrives whose instance state is not `ALIVE` (the tractor's writer is gone:
immediately after an orderly shutdown, or when its 30-second liveliness lease
expires after a crash), the listener calls
`_release_departed_tractor(tractor_id)`. Under `self.lock` it removes every
slot that tractor holds and logs `<tractor> is gone — released slot <id>`. If
one of them was on the dock, it clears `_charging` and calls
`_advance_queue()`. It then publishes `StationStatus`, so the next tractor
learns of its promotion as usual. A crashed tractor therefore cannot block
the dock, and no application heartbeat is needed.

A tractor whose link is down for longer than the lease loses its slot too.
When it returns, it finds itself missing from the queue: a queued tractor
aborts its charge (§8); a docked one finishes charging and sends a release
the station treats as already done.

---

## 13  Queue Advancement

`_advance_queue()` is called while `self.lock` is already held after the docked
slot is released.

It iterates `_queue` in insertion order. The first remaining slot is assigned
to `_charging`; if the queue is empty, `_charging` remains `None`. Since every
accepted reservation is immediately committed, there is no confirmation test.

The callback publishes `StationStatus` after advancement. The promoted tractor
observes rank `0` in that sample and navigates to the dock. There is no separate
promotion RPC.

---

## 14  Thread Summary

| Thread | Daemon | Description | Created by |
|--------|--------|-------------|------------|
| Main | No | Initializes DDS, publishes initial status, and sleeps in one-second intervals | `main()` / `run()` |
| DDS internal threads | Middleware-managed | Discovery, reliability, receive, `SimpleReplier` callback dispatch, and the presence listener | `DomainParticipant` and `rti.rpc` |

The station creates **zero application worker threads**. In particular, it has
no status-publishing thread and no request-processing loops. The exact number
of DDS internal threads is middleware- and configuration-dependent and is not
specified here.

---

## 15  Resilience Behaviour

| Scenario | Behaviour |
|----------|-----------|
| Tractor leaves while reserved | No release arrives; the station frees the slot when the tractor's `OperationalState` instance becomes not alive (at once for an orderly shutdown, after the 30-second lease for a crash) and promotes the next tractor (§12) |
| Unknown or repeated release | Returns `success=true` without changing queue state |
| Release names another station | Returns `success=true` without changing this station's queue |
| Station restart | All queue state is lost because it is memory-only; the initial published status is empty |
| Ctrl-C, SIGTERM, or startup failure | `shutdown()` closes the repliers and the participant, then finalizes the participant factory |
| Reserve reply timeout at tractor | Tractor waits up to five seconds and abandons the attempt if no granted assignment from its chosen station is found |
| Network interruption | Delivery and recovery follow the effective DDS/RPC QoS and endpoint match lifetime |
| Multiple stations | Each station manages its own queue; tractors select shortest queue and then nearest dock from cached `StationStatus` data |
| Late-joining UI or tractor | `StationStatus` uses transient-local last-value behavior while the station writer is alive |

Queue recovery after a station restart, reservation ownership validation, and
durable queue storage are not implemented.

---

## 16  Type Contract Summary

The station uses types generated from `fleet_types.idl`.

### Types Read (via `rti.rpc.SimpleReplier` callbacks)

| Type | Key | Fields Used |
|------|-----|-------------|
| `SlotReserve` | — | `tractor_id`, `station_id`, `battery_level` |
| `SlotRelease` | — | `tractor_id`, `slot_id`, `station_id` |

### Types Written (via `rti.rpc.SimpleReplier` and pub-sub)

| Type | Key | Fields Written | Mechanism |
|------|-----|----------------|-----------|
| `SlotAssignment` | — | `station_id`, `slot_id`, `granted`, `queue_rank`, `dock_x`, `dock_y` | Return from reserve callback |
| `SlotReleaseAck` | — | `station_id`, `slot_id`, `success` | Return from release callback |
| `StationStatus` | `station_id` | `dock_x`, `dock_y`, `is_occupied`, `docked_tractor_id`, `queue[]` | `writers['station_status'].write()` |
| `QueueEntry` | — | `tractor_id`, `rank`, `confirmed` | Nested in `StationStatus.queue` |

### Types Read (via pub-sub)

| Type | Key | Fields Used |
|------|-----|-------------|
| `OperationalState` | `tractor_id` | `tractor_id` only; instance states signal departure (§12) |

All structures are `@appendable`. Relevant string members are bounded to 64
characters, and `StationStatus.queue` is bounded to 16 entries. RPC request and
reply types are unkeyed.

### Interface Contract Summary

| Aspect | DDS contract |
|--------|--------------|
| Service definition | Two `rti.rpc.SimpleReplier` callback pairs plus one status topic |
| Reserve pair | `SlotReserve → SlotAssignment`, service `ChargingSlotReserve` |
| Release pair | `SlotRelease → SlotReleaseAck`, service `ChargingSlotRelease` |
| Correlation | `rti.rpc` uses DDS `SampleIdentity`; no IDL `request_id` |
| Station targeting | `station_id` in each request; non-target stations do not mutate state |
| Queue progress | Event-driven `StationStatus` pub-sub |
| Departed tractors | `OperationalState` instance becomes not alive → the station frees the tractor's slots |
| Status delivery | `RELIABLE / TRANSIENT_LOCAL / KEEP_LAST 1` |
| `QueueEntry.confirmed` | Always `true` in the current immediate-reservation model |

---

## 17  File Structure

The application is a **single Python file** (`charging_station.py`) that:

1. Imports generated DDS types from `fleet_types.py`.
2. Defines `CHARGE_DURATION_ESTIMATE` and `_ts()`.
3. Defines `ChargingStation`:
   - identity, queue, lock, and DDS state (§4);
   - `initialize_dds()` (§6);
   - `_on_slot_reserve()` and `_on_slot_release()` callback wrappers (§6.6);
   - `_handle_slot_reserve()` (§7);
   - `_handle_slot_release()` (§9);
   - `_release_departed_tractor()` (§12);
   - `_publish_status()` (§10);
   - `_queue_rank()` and `_advance_queue()` (§13);
   - `run()` and `shutdown()`.
4. Defines `main()` for CLI parsing and process startup.

Queue waiting-position computation and queue-rank consumption are implemented
by `tractor_node.py`, not by the station.

### Companion files

| File | Purpose |
|------|---------|
| `fleet_types.idl` | DDS IDL definitions and source of truth |
| `fleet_types.py` | Auto-generated Python type support |
| `fleet_qos.xml` | Participant and endpoint QoS profiles |
| `tractor_node.py` | Station selection, waiting-position computation, and charging behavior |
| `demo_start.sh` | Launches configured station processes |

### External Dependencies

| Package | Use |
|---------|-----|
| `rti.connextdds` | Participant, topic, publisher, writer, and QoS APIs |
| `rti.rpc` | Callback-driven request-reply services |

`rti.idl` is used by generated `fleet_types.py`; it is not directly imported
by `charging_station.py`.

### Design Notes

| Concern | How DDS handles it |
|---------|--------------------|
| Station discovery | SPDP discovers participants; SEDP discovers endpoints |
| Request-reply | `rti.rpc.SimpleReplier` invokes reserve and release callbacks |
| Correlation | DDS `SampleIdentity` metadata managed by `rti.rpc` |
| Status delivery | `StationStatus` uses reliable, transient-local last-value behavior |
| Rank changes | Published state drives tractor queue movement |
| Tractor departure | Instance state of the tractor's `OperationalState` (liveliness or writer deletion) |

---

## 18  Deployment

Charging stations are launched by `demo_start.sh` before tractor nodes. Typical
configuration:

```bash
# Station 1 — top-left corner
python charging_station.py --id station1 --dock-x 8 --dock-y 92 &

# Station 2 — bottom-right corner
python charging_station.py --id station2 --dock-x 92 --dock-y 8 &
```

Each station joins the selected DDS numeric domain using the participant domain
tag configured in `FleetQosLibrary::ParticipantProfile`. Tractors discover the
station through SPDP and match the request-reply and status endpoints through
SEDP.
