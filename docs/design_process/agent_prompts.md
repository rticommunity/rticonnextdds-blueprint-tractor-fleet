# Agent Prompts

The key prompts used with an AI coding assistant to design and build the
tractor fleet. Smaller iterations (UI polish, bug fixes, wording)
are left out. What remains are the decisions that shaped the system:
components, interfaces, data model, QoS, discovery, and algorithms.

Each entry shows the prompt, lightly edited for typos and brevity, followed
by a `>` summary of the outcome. Early prompts say "robot"; the robots became
tractors later. Interactions with the **Connext MCP** servers (RTI's Connext
knowledge expert and runtime inspection tools) are noted under the entry they
informed. The expert corrected the assistant twice (entries 32 and 34), which
led to a standing instruction: check with the Connext tool instead of
assuming.

---

# Part 0: First Implementation

The starting point: a working Connext DDS application generated from the
scenario in [high_level_scenario.md](high_level_scenario.md).

# 0.1 Create the first robot application
Can you create a Python application for a robot that uses Connext DDS for all
communications: publish-subscribe for state, intent, and telemetry, and
request-reply for commands? (The scenario was attached.)

> The first version: type definitions, QoS profiles, a robot node, and a
> command console. Initial QoS per kind of data: state best-effort (latest
> value matters, loss is fine), intent reliable and transient-local (late
> joiners get the current intent), telemetry best-effort, and commands
> reliable. Peers are found by automatic discovery with no address
> configuration, and DDS liveliness detects robots that disappear (initially
> with a 100 ms lease, relaxed later in entry 32).

# 0.2 QoS in XML, not in code
Can you change the robot node to configure QoS from the XML file instead of
doing it in the code?

> All QoS moved into named XML profiles loaded through a `QosProvider`, and
> the code only references profile names. Every later QoS change in this log
> is an XML change.

---

# Part 1: Domain and Behavior

Technology-independent decisions about what the vehicles do and say.

# 1 Separate status from intent
I am still unclear what the commands, intent, and status are. This does not
seem consistent: IDLE status is not consistent with a PATROL behavior, and
START does not seem like a good command to change to IDLE. Can you rethink
the commands, statuses and intent so this all makes logical sense?

What is the difference between Status and Intent? They seem to carry the
same info. Should the status be only MOVING or STOPPED and the intent
PATROL, GOTO, or IDLE?

> Status became the physical state (what the body is doing) and intent the
> mission (why). They carry independent information, so any combination is
> meaningful, for example GOTO + STOPPED is a mission paused mid-way.

# 2 Enums in the data model
I want the status and intent to not be strings. They should be enums so it is
clear in the data model what the options are.

> Status, intent, and command became enums in the type definitions.

# 3 Collision avoidance
The avoidance parameters let the robots get too close, and based on their
graphical size they are seen as colliding. What is the distance the avoidance
algorithm is trying to keep between robots? Explain the algorithm first and
how you would fix it before making changes.

> Each vehicle applies a linear repulsion from every peer inside an avoidance
> radius, added to its goal-seeking velocity, using the peers' published
> positions. The equilibrium distance (where repulsion equals cruise speed)
> was too small; the radius and strength were raised so vehicles keep clear.

# 4 Publish state on significant change
State also includes the current position, which is always changing unless
the robot is holding or idle. How complex is it to send only on significant
change for position and battery, plus a heartbeat? Don't make changes yet.

> Kept as two topics with different policies: KinematicState stays periodic
> (10 Hz, it changes every tick while moving), and OperationalState is
> published only when status or battery changes. In the DDS design, liveliness
> and durability later replaced any application heartbeat (entry 21).

# 5 Synthetic onboard video
I was thinking of something where the synthetic video is based on the
position of the robot and the other robots. Is there a simulator that can be
integrated to generate the video stream from the actual robot positions?

Will PyBullet 3D look better? What platforms will it run on? I want the
synthetic video to be sent from the robot to the UI.

> Each vehicle renders a first-person 3D view with PyBullet in headless mode
> (CPU TinyRenderer, no GPU or display needed), using the peer positions it
> already receives, and publishes JPEG frames.

# 6 Charging stations allocate slots
Let's say there is one charging station but multiple robots need charging.
How would this be handled?

I was thinking that robots could decide to charge, but the UI could also
command a robot to charge. The charging stations allocate slots. Robots
would request a slot and then go there and wait.

> Charging stations became their own autonomous processes that own a queue of
> slots. A vehicle starts charging on low battery (drain depends on speed) or
> on an operator CMD_CHARGE, reserves a slot, drives to the dock or a wait
> position, charges, releases the slot, and resumes its previous intent. The
> negotiation protocol was simplified later (entries 17–18).

# 7 Queue and dock intents
Is the intent available to other robots? Maybe there could be two intents,
"CHARGE_WAITING" and "CHARGING". Would that be cleaner?

> INTENT_CHARGE_QUEUE (waiting) and INTENT_CHARGE_DOCK (rank 0, heading to or
> on the dock). Peers can now see which vehicle to yield to, so the avoidance
> logic uses published intent instead of guessing from status.

# 8 Holding at a goal and resuming after charging
What is the purpose of INTENT_IDLE with STATUS_HOLDING? Would this be better
modeled as intent GOTO with status HOLDING?

A tractor that was holding at a position (for example after a GOTO) and then
charges should go back to that position after charging, not wait around the
charging area.

> Arriving at a GOTO target keeps INTENT_GOTO with STATUS_HOLDING (holding
> position, avoidance active). Because the mission is preserved, restoring the
> pre-charge intent naturally returns the vehicle to where it was.

# 9 Domain vocabulary
Is PATROL the right command and term to use for tractors in a field?

> Renamed to follow a path: CMD_FOLLOW_PATH and INTENT_FOLLOW_PATH, the
> tractor working its route of waypoints.

---

# Part 2: Connext DDS Design

# 10 Design principle
Can you look at the README and check it is consistent with the updated
scenario? The goal is to meet the scenario requirements in the most natural
and simplest way for DDS, taking full advantage of DDS features.

> The guiding rule for the rest of the design: if DDS already provides
> something (discovery, late-joiner state, liveliness, correlation,
> timestamps), the application does not reimplement it.

# 11 Topic data model
Update the type definitions to incorporate all the types needed in the
design of the README.

> The vehicle state was split by concern and rate into KinematicState,
> OperationalState, Intent, Telemetry, and VideoFrame, each keyed by vehicle
> ID, plus StationStatus for the stations. Helper structs (Position,
> Velocity3, Waypoint) and enums give a typed model.

# 12 No timestamps in the types
Why do we need timestamps in the topic types? Connext already includes a
source and reception timestamp with every sample.

> All timestamp fields were removed. Readers use
> `SampleInfo.source_timestamp`.

# 13 QoS from built-in patterns
Why not use Pattern.RPC for the request/reply profiles?

> Every QoS profile derives from a built-in pattern, with only the
> differences written out: KinematicState from Pattern.PeriodicData
> (best-effort, deadline), OperationalState from Pattern.Status and Intent from
> Pattern.LastValueCache (reliable, transient-local, keep-last 1), Telemetry
> and video from Pattern.Streaming, and commands and slot negotiation from
> Pattern.RPC (reliable, keep-all, tuned heartbeat/NACK timing).

# 14 Generated types
I would prefer to generate the Python classes from the type definitions with
rtiddsgen instead of defining them by hand.

> Type support is generated by `rtiddsgen`, so the type file is the single
> source of truth and about 170 hand-written lines disappeared.

# 15 Request-reply with Requester and Replier
The robot node is not using Requester and Replier objects for the RPC. Using
Requester/Replier for the commands and slot negotiation would be simpler. A
Connext Requester can send the same request to all implementations of the
service and receive the responses from all of them when needed.

> Commands and slot negotiation moved from hand-built topic pairs to
> `rti.rpc` Requester/Replier, removing manual correlation and polling loops.

# 16 No request IDs
I do not understand why the request/reply types have a request_id. I thought
Connext automatically uses sequence numbers and writer/reader GUIDs to
correlate them.

> Removed from every request/reply type. `rti.rpc` correlates replies with
> the request's SampleIdentity (writer GUID + sequence number).

# 17 Self-describing replies
A request goes to all stations and a single Requester gets all the replies,
so it must look at the content to know where each reply comes from. Are we
missing data in the messages? SlotAssignment does not contain the station_id
or slot_id, and SlotRelease does not contain the station_id. If all the
necessary information were in the messages, the logic could be simpler.

> Replies and releases carry station_id and slot_id, and each station ignores
> releases addressed to another station.

# 18 Reserve with a single directed request
Why do we need the SlotRequest/SlotOffer logic? The robot can already see
which station has the shortest queue, so it could just reserve the next
available slot with a single directed request. There is no need for
offer/accept/reject.

> Stations publish StationStatus (location, occupancy, queue). Each vehicle
> picks the best station locally and sends one SlotReserve → SlotAssignment;
> later SlotRelease → SlotReleaseAck. The offer/confirm phase, its expiry
> logic, and a station thread were removed.

# 19 Video only when someone is watching
A more natural DDS approach is that the robot creates the DataWriter but only
sends video if there is a matched DataReader.

> The vehicle renders and publishes frames only while its video writer has a
> matched reader, so no command is needed to start or stop video.

# 20 Selecting the video source with partitions
I would like a content filter in the UI so only the robot of interest sends
data on the network.

A better approach: the UI keeps one reader with a content-filtered topic
whose parameter is the robot ID, plus a propagated property naming the robot
of interest. I do not like polling the matched publications. We could also
watch the built-in subscription topic.

There is a third option: partitions. The robot publishes video in a
partition named after its ID, and the UI subscribes to the partition of the
robot it wants to see. Partition changes cause matches and unmatches, which
are notified on publication matched. They are also more efficient, since no
filter runs on each sample.

> Partitions won: each vehicle's video writer uses a partition named after
> its ID, and the UI's reader starts in a partition that matches nothing and
> switches to the selected vehicle. Exactly one vehicle renders and sends.
> Content filters, propagated properties, and built-in topic monitoring were
> tried or considered and dropped.

# 21 Remove redundant heartbeats
Can you think of any more simplifications based on the capabilities of DDS?
Remove extra heartbeats, etc. As you said Intent could go on change; why keep
it periodic?

> The stations' periodic StationStatus re-publish was removed (reliable +
> transient-local already serves late joiners), and Intent is published only
> on change. KinematicState and Telemetry stay periodic because they are
> sampled data.

# 22 XML Application Creation (deferred)
Can initialization be simplified using XML Application Creation? It could
also be used for the tractor and the UI, so everything is declarative.

> It works, but for now the entities stay in code. A fully declarative
> topology in XML was parked as a possible future step.

# 23 Callback dispatch for replies
Does the Python API dispatch callbacks on Repliers so I do not need to call
receive_requests and iterate over them?

> Commands are handled by `rti.rpc.SimpleReplier` with a handler callback,
> removing two application threads and their loops.

# 24 Inspecting the running system
Tell me what is running in my Connext system. Give me the current position of
all the tractors and their current intent.

> The assistant used the Connext runtime MCP to list participants, topics,
> writers, and readers, and to read live samples.

## 24.1 Connext MCP (runtime)
> `ask_model_graph` returned the system overview (one domain, the fleet's
> participants and topics) and an analysis of possible QoS issues.
> `subscribe_to_topic` and `read_topic_samples` returned live
> KinematicState, OperationalState, Intent, Telemetry, and StationStatus
> data, from which the assistant reported each tractor's position and intent.

# 25 Stop and resume semantics
When the robot is told to stop and then resume, it should keep its intent. On
resume it should go back to the status it had (moving, charging, or holding).

> STOP only pauses (STATUS_IDLE) without changing the intent or the charging
> workflow. RESUME restores the previous status.

# 26 Consistent types
The Intent type uses target_x and target_y instead of the Position struct
used elsewhere. This seems inconsistent.

> Intent's target is a Position.

---

# Part 3: Refinement

# 27 IDL as the single source of truth
Should I just use the IDL and drop the XML type definitions? rtiddsgen can
run from the IDL, and that removes a set of files.

> `fleet_types.idl` became the only type definition, with the design notes
> moved into its comments. All language bindings are generated from it.

# 28 Coverage trail that survives restarts
Each tractor publishes CoveragePoint samples while working its path,
filtered at the source to at least one arena unit apart, with RELIABLE and
PERSISTENT durability. RTI Persistence Service, started with the demo,
stores the trail across restarts.

If the tractor reports a CoveragePoint, the UI draws a line from the last
point to the new one. That is not always correct, for example when the
tractor is sent elsewhere and later resumes, or when Persistence Service
replays old paths. I do not like to rely on time.

> The UI breaks the trail when consecutive points are farther apart than a
> gap threshold. Time-based detection was rejected, and a segment ID in the
> type was considered but not adopted.

# 29 Transport and participant names
Update the QoS to disable shared memory. Set the participant name for each
DomainParticipant: the name should identify each application instance and
the role name the kind of application.

> UDPv4 only, so all traffic goes over the network stack and the demo
> behaves the same on one host or many. Participants are named (for example
> `tractor1`, role `Tractor`) so tools such as Admin Console show them clearly.

# 30 Install from PyPI
rti.connext is now in the standard pip repository. Should we check in the
generated types so that running the demo does not require regenerating them?

> Python dependencies install from PyPI and the generated `fleet_types.py` is
> committed. A Connext installation is still needed for `rtiddsgen` and
> Persistence Service.

# 31 Non-holonomic steering
When the robots get close and repel each other, their motion looks
unnatural: they instantly rotate to a new direction. Real tractors cannot
rotate in place.

> Vehicles steer toward the desired direction with a maximum turn rate
> (2 rad/s) and always drive forward along their heading.

# 32 Discovery and liveliness traffic
I see a lot of automatic liveliness messages, very frequent. Why? I also see
very frequent participant announcements. I want to configure the use of
SPDP2 (or not) explicitly in the QoS so I know what is happening.

> A 100 ms liveliness lease made every participant assert about every 33 ms;
> it was raised to 30 s (KinematicState at 10 Hz already shows presence). The
> participant profile selects the discovery plugins explicitly: classic SPDP
> for interoperability, with SPDP2 documented as an option.

## 32.1 Connext MCP
> Asked what `Optimization.Discovery.Endpoint.Fast` changes. The expert
> answered that it only tunes the endpoint-discovery writers, not participant
> announcements, so the frequent announcements had another cause.

# 33 Multicast for multi-reader topics
DDS is not using multicast for the data. Add multicast to the topics that
have multiple receivers.

> KinematicState, OperationalState, and Intent readers receive on multicast
> addresses, so each sample is sent once instead of once per reader (for
> KinematicState alone, about 350 → 50 packets/s with five tractors). Topics
> with a single reader stay unicast.

# 34 TypeObject V1 (test)
Can you temporarily disable TypeObject V2? I want to test TypeObject V1.

Always check with the Connext tool; don't assume you know the answer without
checking. There may be multiple ways, and some may be considered best
practice. I got a different answer from the manual: add the
Feature.TypeSupport.V2.Disable and V1.Enable snippets. Can you check with the
Connext tool whether that is a good approach?

> Kept as a commented-out option in the participant profile; TypeObject V2
> (the default) stays on.

## 34.1 Connext MCP
> The expert explained the manual settings (disable the TypeLookup channel,
> set `type_object_max_serialized_length`), confirmed the snippets are the
> recommended way, and gave the correct prefix:
> `BuiltinQosSnippetLib::`, not `BuiltinQosLib::`. It also advised keeping
> TypeObject V2 unless compatibility requires V1. The assistant's first
> answer, a participant property, was not the recommended approach.

# 35 Receiving your own data
Are there QoS incompatibilities between writers and readers? If a
participant creates a DataReader on the same topic as its DataWriter, does it
get its own data?

> Yes, by default. Each tractor's listeners skip samples with its own
> `tractor_id`; `ignore_local_publications` is the DDS-level alternative.

## 35.1 Connext MCP
> The expert confirmed local delivery is on by default and explained that
> `ignore_local_publications` controls it, while `ignore_loopback_interface`
> is an unrelated transport setting.

# 36 Domain tag isolation
I would like all participants to use the domain tag "tractor-fleet-salinas-CA"
so they do not interfere with other DDS applications on the same domain ID.
Would it make sense to set DOMAIN_ID and DOMAIN_TAG as environment variables
in a shared script?

> The participant profile sets the propagated domain tag. Persistence Service
> uses a custom configuration (`fleet_persistence.xml`) whose participants
> carry the same tag, since its built-in configurations don't load the
> application's profile. Launch scripts export DOMAIN_ID and DOMAIN_TAG from
> `shared/fleet_common.sh`; `fleet_persistence.xml` expands `$(DOMAIN_TAG)`
> with a fallback default in `<configuration_variables>`.

## 36.1 Connext MCP
> Three answered questions: the supported property
> (`dds.domain_participant.domain_tag`, propagated, fixed at creation);
> how Persistence Service joins the tag (no `-domainTag` option, so use a
> configuration derived from the built-in disk configuration); and XML
> variable expansion (`$(VAR)` with defaults in `<configuration_variables>`,
> environment first; `$(VAR=default)` is not supported).

# 37 Consistent, complete shutdown
Looking at how the applications handle KeyboardInterrupt and shutdown
cleanup, there are inconsistencies. Some have a dedicated shutdown function
and call it from a try/finally; others call the cleanup inline from an
exception handler. Is there a reason for this? What is the best practice?
Shouldn't all use the same approach?

> No reason; the code had drifted. Every application now follows one
> pattern: a dedicated shutdown path called from `finally`, so it runs on
> Ctrl-C, on errors, and during startup failures. The first version assumed
> `finally` also runs on SIGTERM, which is what `demo_stop.sh` sends; by
> default Python exits on SIGTERM without unwinding. Each `main()` now maps
> SIGTERM to the Ctrl-C path. The shutdown order matters: close the
> `rti.rpc` Requesters and Repliers first (each owns an internal WaitSet, and
> a participant refuses to close while one is attached), then the
> participant, then finalize the participant factory. Peers then see a
> stopped tractor leave immediately, instead of after its 30 s liveliness
> lease.

# 38 Topic names describe the flow
I do not like "VideoFrame" as a topic name. It is fine as a type name. Can
you suggest a better name? Is LiveVideo or OnboardVideo better?

> The topic became `LiveVideo`; the type stays `VideoFrame`. The topic names
> the flow and the type names one sample, which also shows that topic and
> type are separate in DDS. `LiveVideo` matches the original scenario and
> hints at the QoS (best-effort, volatile, nothing replayed); `OnboardVideo`
> would only pay off if other video sources, such as field cameras, were
> added.

# 39 Acting on presence
It's too bad that the "why DDS" message is weakened by "tractors log
liveliness changes, and nothing acts on missed deadlines." Would it not be
better to do something with the liveliness changes and missed deadlines?
What would make sense?

I do not like the tractor name being part of the contract, or forcing each
tractor to be a separate participant. Perhaps subscribing to
OperationalState is the best approach.

> Applications now act on presence through DDS alone, with no heartbeat code.
> The dashboard shows each tractor as live, stale (its `KinematicState`
> deadline missed: a pulsing ring and "no update for N s"), or offline (its
> writer gone: a grey dashed ring, removed after 10 s). Tractors stop
> steering around a departed peer's last position, and stations free its
> charging slot and promote the next tractor. Each reacts to the reader
> instance state `NOT_ALIVE_NO_WRITERS`: at once after an orderly shutdown,
> after the 30 s liveliness lease after a crash. Stations watch
> `OperationalState` rather than built-in participant discovery, so the
> tractor's identity comes from the IDL key, not from participant names, and
> nothing assumes one tractor per participant.

# 40 Commands to one tractor or the whole fleet
The README does not mention the benefit of being able to send a command to a
single tractor or to many tractors (e.g., telling all to stop or resume their
path). This is something Connext naturally supports, and it's more
cumbersome in traditional RPC.

Why not use "ALL" instead of "*", unless you are planning to do real
expression matching?

Can a content filter be added so that only the target tractor gets the
command? Is that supported by the Replier?

> The dashboard's "all tractors" action had sent one request per tractor,
> one after another. Now a request addressed to `ALL` (a reserved tractor ID)
> reaches every tractor at once, and the dashboard collects the correlated
> replies. Each tractor's replier reads requests through a content filter
> (`tractor_id = <own id> OR tractor_id = 'ALL'`), evaluated at the writer, so
> a command for one tractor reaches only that tractor. The Python
> request-reply API accepts a content-filtered request topic with generated
> types; a test confirmed one reply for a targeted command, one per tractor
> for `ALL`, and none for an unknown ID.
