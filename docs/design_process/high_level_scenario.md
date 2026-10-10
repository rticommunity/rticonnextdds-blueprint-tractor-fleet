# High-Level Scenario

The scenario description that started the project. It was
written for a generic fleet of autonomous robots; the robots later became
tractors working a field. Recovered from the project's working files and
kept as originally written, apart from small formatting and wording fixes.

# System Description
- Robots: Variable number of autonomous robots/vehicles/drones (5- 1000)
  - Each "robot" produces information about itself
    Produces `KinematicState (Position, Velocity){robot_id}`, `OperationalState{robot_id}`, `Intent{robot_id}`, `Telemetry{robot_id}`, `LiveVideo{robot_id}`
    - `Telemetry` includes CPU, memory, motor temperature, and **signal strength / link quality** (relevant to the mixed-connectivity scenario — WiFi/5G/radio)
  - Each robot implements a command service interface
  - Each robot consumes information about all other robots `KinematicState{robot_id}`, `OperationalState{robot_id}`, `Intent{*}`
  - Each robot is a separate (autonomous) process
- FleetUI
  - Views robots sends commands to the robots. Can request live video from any of the robots
- Charging stations: Variable number
  - Allow robots to reserve and queue for charging
  - Implements service interface for querying and slot reservation
  - Each station is a separate (autonomous) process
- Future potential additional consumers: recorder, safety monitor, cloud ingest

# Key requirements:
- **late joiners converge on current truth** quickly; system tolerates churn
- Robots must detect presence/absence of other robots with a maximum delay of 100ms
- Robots can appear dynamically. There should be no a-priori manual configuration of number/addresses
- Robots must know the latest KinematicState of other robots within a small tolerance (e.g position within 1 meter, velocity within 1 m/s)
- KinematicState can be sent periodically or when it changes significantly to allow others to always know it within the tolerance
- The latest OperationalState, and Intent must be known reliably. It should be sent on change.
- Telemetry is sent periodically. Loss of periodic telemetry is tolerable.
- Commands are reliable

# Scenario Description
- Robots and charging stations come and go
- IP addresses change
- Mixed connectivity (Wifi/5G/radio) temporary disconnects

# Implementation Guidelines
- use python
- use Connext DDS for all communications
- Pub-Sub DDS for state, video, telemetry, intent
- DDS-RPC for service calls for command service interface
