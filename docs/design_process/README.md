# Design Process

This directory records how the tractor fleet was designed and built with
RTI Connext DDS using an AI coding assistant, together with RTI's Connext
MCP servers (the Connext knowledge expert and runtime inspection tools). It
is a learning resource: it shows which decisions mattered and how they were
reached, not every iteration.

## Reading Order

1. **[high_level_scenario.md](high_level_scenario.md)**: the original
   scenario and requirements that started the project
2. **[agent_prompts.md](agent_prompts.md)**: the key prompts and their
   outcomes, from domain behavior through the Connext DDS design (data model,
   QoS, request-reply, discovery) to later refinements, including every
   interaction with the Connext MCP

The resulting design is described in [DESIGN.md](../DESIGN.md) and the
per-component specifications in [python/spec/](../../python/spec/).
