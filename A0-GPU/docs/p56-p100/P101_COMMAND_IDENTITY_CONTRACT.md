# P101 — command identity and immutable submission contract

This document describes ONLY the experimental Python software reference.

- `CommandBuffer.seal()` must freeze command order, opcode, handle and nested payload *values* against public caller mutation.
- `CommandBuffer.commands` and `.sealed` are read-only public accessors. Command sequence returned to external callers cannot mutate the stored sealed commands.
- A `ResourceTable` handle is a 32-bit identity `generation[31:16] | slot[15:0]`; generation zero is invalid. Once the generation would exceed `0xffff`, its slot is permanently retired. No stale identity is ever reissued.
- Exhaustion raises `DeviceFault` instead of silently reviving an old handle.
- This is a Python software-level safety property, not a hardware ABA proof or security sandbox. For high-churn production devices, implement wider epochs/handles with formally checked reuse and a defined exhaustion policy.
