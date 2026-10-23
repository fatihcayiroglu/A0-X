# A0 RTL Architecture

## A0-RTL0 Synthesizable Wave Execution Core

A0-RTL0 introduces the first synthesizable SystemVerilog implementation of the
A0 execution architecture.

The RTL is validated against the Python A0GPU architectural golden model using
the same assembled 64-bit A0 machine-code program.

This milestone marks the transition from software-only architecture exploration
to executable hardware description.

## RTL0 Scope

The initial RTL wave core implements:

    VADD
    VSUB
    VMUL
    VAND
    VOR
    VXOR

    SADD
    SSUB

    VCMP_EQ
    VCMP_LT
    VCMP_LE

    vector predicate-controlled execution

    HALT

The core contains architectural state for:

    vector registers
    scalar registers
    vector predicate registers
    EXEC_MASK
    program counter
    program memory

The implementation currently models one logical A0 wave.

## Instruction Format

RTL0 consumes the same experimental 64-bit A0 instruction encoding used by the
Python ISA model and assembler.

The RTL decoder currently extracts:

    opcode
    flags
    destination register
    source register 0
    source register 1
    predicate index

No separate RTL-only instruction encoding exists.

This is intentional: the binary contract shared by software and hardware is
part of differential verification.

## Vector Execution

Vector integer operations execute over the logical A0 wave.

For every lane, writeback is enabled only when:

    EXEC_MASK[lane] == 1

and, for predicated instructions:

    selected predicate[lane] == 1

Inactive lanes retain their previous destination-register value.

The RTL0 implementation currently describes all logical lanes directly.

This must not be interpreted as a frozen physical SIMD width.

Future RTL generations may time-multiplex a logical wave across a smaller
physical SIMD datapath.

## Scalar Execution

RTL0 implements the initial scalar arithmetic operations:

    SADD
    SSUB

Scalar register state is maintained independently of vector register state.

## Vector Comparisons

The following vector comparison instructions produce per-lane predicate state:

    VCMP_EQ
    VCMP_LT
    VCMP_LE

Each active lane independently writes one predicate bit.

These predicate results can immediately control later predicated vector
instructions.

## Fail-Closed Unsupported Opcode Behavior

RTL0 intentionally supports only its declared subset.

If an instruction outside the RTL0 supported subset reaches the execution core,
the core enters:

    faulted = 1
    halted = 1

This avoids silently interpreting unsupported instructions incorrectly.

## Configuration Interface

Before execution, the current RTL0 test environment can initialize:

    program memory
    vector registers
    scalar registers

Execution begins only after run_enable is asserted.

This configuration interface exists primarily for architectural verification and
is not intended to be the final GPU command processor or dispatch interface.

## Differential Verification

A0-RTL0 introduces an automated Python-to-RTL differential verification flow:

    A0 assembly source
        -> A0 assembler
        -> identical 64-bit machine words
        -> Python A0GPU execution
        -> SystemVerilog RTL execution through Verilator
        -> complete architectural-state comparison

The current differential workload exercises:

    VADD
    VSUB
    VMUL
    VAND
    VOR
    VXOR

    SADD
    SSUB

    VCMP_EQ
    VCMP_LT
    VCMP_LE

    predicated VADD

    HALT

The verifier compares:

    64 vector registers
    * 32 lanes
    = 2048 vector register words

    32 scalar registers

    16 vector predicate registers

A mismatch reports the exact architectural resource that differs.

Examples include:

    VECTOR_DIFF
    SCALAR_DIFF
    PREDICATE_DIFF

## RTL0 Verification Result

The initial RTL0 differential workload contains 13 A0 machine instructions.

The verified state comparison covers:

    2048 vector words
    32 scalar words
    16 predicate masks

The RTL and Python golden model produce matching architectural state.

Verilator lint also accepts the synthesizable wave-core RTL without errors.

## Integration Gaps Found by Differential Verification

The first RTL differential bring-up exposed several previously hidden
cross-layer inconsistencies.

### Compare assembler coverage

The ISA defined:

    VCMP_EQ
    VCMP_LT
    VCMP_LE

but the assembler initially accepted only VCMP_LT.

The assembler was generalized so all three existing ISA operations use the same
operand form.

### Vector bitwise golden-model coverage

The ISA and assembler defined:

    VAND
    VOR
    VXOR

but the Python architectural execution model did not execute them.

Their functional semantics were added and regression tested.

### Vector compare golden-model coverage

The ISA, timing metadata and RTL supported:

    VCMP_EQ
    VCMP_LT
    VCMP_LE

while the Python architectural executor initially implemented only VCMP_LT.

The golden simulator was extended to execute all three comparison operations and
an independent regression test was added.

These findings demonstrate why end-to-end differential verification is required
in addition to isolated component tests.

## Current RTL0 Limitations

RTL0 does not yet implement:

    JMP
    BRA

    SPLIT
    ELSE
    JOIN

    scalar predicates

    global memory
    indexed global memory

    LDS/shared memory
    BARRIER

    FP32 arithmetic

    cache hierarchy

    timing scoreboard

    multi-wave scheduling

    occupancy admission

    register-file banking

    physical SIMD partitioning

    pipeline stages

    execution-unit latency

    instruction fetch hierarchy

    command processor

The absence of these features is deliberate.

RTL0 establishes a small trusted hardware base before expanding into more complex
state and synchronization behavior.

## Synthesizability Status

The RTL0 wave core is written as synthesizable SystemVerilog and passes Verilator
lint/elaboration.

However, passing RTL lint does not establish acceptable:

    FPGA utilization
    ASIC area
    clock frequency
    timing closure
    power
    register-file implementation quality

Those properties require synthesis and physical implementation experiments.

## Architectural Status

A0-RTL0 proves that the experimental A0 binary ISA can drive both:

    the Python architectural golden model

and:

    an independent SystemVerilog hardware implementation

with matching architectural results.

The implementation is the first hardware execution baseline for future A0 RTL
development.

Logical wave size, physical execution width, pipeline organization and register
implementation remain unfrozen.

## A0-RTL1 Control Flow and SIMT Reconvergence

A0-RTL1 extends the synthesizable wave execution core with the first hardware
implementation of A0 control flow and structured SIMT divergence.

### RTL1 Instruction Scope

A0-RTL1 adds:

    SCMP_LT

    JMP
    BRA

    SPLIT
    ELSE
    JOIN

to the RTL0 execution subset.

### Scalar Predicates

The RTL now contains scalar predicate state:

    Q0-Q15

SCMP_LT compares two scalar registers and writes one scalar predicate.

BRA consumes a scalar predicate and performs a uniform branch when the
predicate is true.

### PC-Relative Control Flow

JMP and BRA use the same experimental signed IMM24 PC-relative semantics as the
Python golden model.

The architectural model advances PC to the next instruction before applying the
branch displacement.

Therefore the effective branch target is:

    target =
        current_pc
        + 1
        + sign_extend(IMM24)

RTL1 implements the same behavior.

Out-of-range branch targets fail closed by entering the faulted and halted
state.

### Reconvergence Stack

RTL1 introduces a configurable reconvergence stack.

Each SPLIT stores:

    parent EXEC_MASK
    deferred ELSE mask
    ELSE-entered state

The THEN execution mask is:

    parent EXEC_MASK
    AND
    predicate mask

The deferred ELSE mask is:

    parent EXEC_MASK
    AND
    NOT predicate mask

ELSE activates the deferred mask.

JOIN restores the saved parent EXEC_MASK and pops the stack.

### Structured Divergence

A typical RTL1 divergence sequence is:

    VCMP_LT
        -> P0

    SPLIT P0
        -> THEN lanes active

    THEN instructions

    ELSE
        -> deferred ELSE lanes active

    ELSE instructions

    JOIN
        -> parent EXEC_MASK restored

The RTL1 differential workload verifies a 16-lane / 16-lane split within the
current 32-lane logical wave.

### Fail-Closed Reconvergence Errors

RTL1 faults and halts on invalid control-stack behavior including:

    SPLIT when the reconvergence stack is full
    ELSE with an empty stack
    duplicate ELSE for one SPLIT
    JOIN with an empty stack

This mirrors the project's general fail-closed verification approach.

### RTL1 Differential Verification

The RTL1 differential program combines uniform and divergent control flow.

It performs:

    scalar loop:
        SADD
        SCMP_LT
        BRA backward

followed by:

    VCMP_LT
    SPLIT
    THEN vector arithmetic
    ELSE
    ELSE vector arithmetic
    JOIN

followed by:

    JMP
    skipped vector instruction
    HALT

The loop reaches:

    S0 = 5

before leaving through the scalar predicate branch.

### Compared Architectural State

RTL1 differential verification compares:

    2048 vector register words
    32 scalar register words

    16 vector predicate masks
    16 scalar predicates

    final PC
    final EXEC_MASK
    final reconvergence stack depth

The verified final control state is:

    EXEC_MASK = 0xFFFFFFFF
    reconvergence depth = 0

This proves that divergent execution reconverges before HALT.

### Compatibility

The original A0-RTL0 differential workload continues to pass after the RTL1
control-flow implementation.

RTL1 therefore extends the existing hardware baseline without breaking its
previously verified instruction subset.

### RTL1 Limitations

A0-RTL1 still does not implement:

    global-memory hardware
    indexed-memory hardware

    LDS/shared memory
    BARRIER

    FP32 execution hardware

    multi-wave scheduling
    scoreboard/hazard tracking

    cache hierarchy

    occupancy admission

    physical SIMD partitioning
    pipeline stages

The current reconvergence stack depth is configurable and experimental.

Its depth, implementation style and eventual relationship to compiler-generated
control flow are not frozen.

### Architectural Status

A0-RTL1 establishes the first synthesizable A0 hardware capable of both:

    uniform program control flow

and:

    structured per-lane SIMT divergence/reconvergence

while remaining differential-equivalent to the Python architectural golden
model for the verified instruction subset.

## A0-RTL2 Indexed Global Memory Interface

A0-RTL2 introduces the first synthesizable external global-memory transaction
boundary in the A0 wave execution core.

This milestone extends the RTL architecture beyond register-only execution and
control flow into externally serviced architectural memory operations.

### RTL2 Instruction Scope

A0-RTL2 adds hardware execution for:

    VLOADX
    VSTOREX

The existing A0 binary instruction format remains unchanged.

VLOADX uses:

    destination vector register
    scalar base register
    vector offset register
    signed IMM24 displacement

VSTOREX uses:

    source vector register
    scalar base register
    vector offset register
    signed IMM24 displacement

### SRC2 Decode

RTL2 completes hardware decoding of the SRC2 instruction field:

    SRC2 = instruction[33:28]

This field is required by VSTOREX because its vector data source is encoded in
SRC2.

The RTL decoder now exposes:

    DST
    SRC0
    SRC1
    SRC2
    PRED

from the shared 64-bit A0 binary instruction format.

### Effective Address

For each active lane, indexed global-memory operations calculate a word address:

    scalar_base
    + vector_offset[lane]
    + signed IMM24

Scalar base and vector offset values are interpreted as unsigned 32-bit
architectural values.

The immediate contribution is sign extended.

Addresses in the current RTL2 interface are word addresses rather than byte
addresses.

### External Memory Boundary

Global memory is intentionally not embedded inside the wave execution core.

Instead, RTL2 exposes an external request/response interface containing:

    request valid
    load/store direction
    active-lane mask
    per-lane word addresses
    per-lane store data

and receives:

    response valid
    response fault
    per-lane load data

This boundary is intended to allow later insertion of:

    memory coalescing
    cache hierarchy
    memory queues
    memory controllers

without changing architectural wave semantics.

### Memory Stall State

A wave that launches a memory request enters a waiting state.

While waiting:

    instruction execution is stalled
    PC does not advance further
    no second memory request is launched

When the response arrives:

    VLOADX writes returned data to active destination lanes
    VSTOREX completes without vector-register writeback

The current implementation therefore supports one outstanding architectural
memory request per wave.

This is a correctness baseline and not the final throughput architecture.

### Predication

VLOADX and VSTOREX obey the existing A0 vector execution mask contract.

A lane participates only when:

    EXEC_MASK[lane] == 1

and, for predicate-qualified instructions:

    predicate[lane] == 1

Inactive lanes:

    generate no memory request
    perform no load writeback
    perform no store
    do not participate in address validation

### Bounds Validation

RTL2 validates every active lane before launching the external request.

Every active effective address must satisfy:

    0 <= address < GLOBAL_MEMORY_WORDS

If any active lane is invalid:

    faulted = 1
    halted = 1

and:

    no external memory request is emitted

This is fail-closed behavior.

### Masked Invalid Addresses

Inactive lanes may contain address values that would be invalid if executed.

Because masked lanes do not participate in the memory instruction, these values:

    do not fault
    do not generate external requests
    do not modify architectural state

RTL2 differential verification explicitly tests this behavior.

### Active Invalid Addresses

The directed RTL2 fault workload gives active lanes addresses outside the
configured global-memory range.

The hardware detects the invalid address before request launch.

The verified result is:

    faulted = 1
    halted = 1
    external memory requests = 0

The Python architectural model independently reports the same access as invalid.

### RTL2 Differential Verification

A dedicated Verilator testbench provides an external architectural RAM model.

The RTL2 verification flow is:

    A0 assembly
        -> A0 binary machine code

        -> Python A0GPU golden execution
        -> Python architectural memory

and independently:

    same A0 machine code
        -> SystemVerilog wave core
        -> external per-lane memory request
        -> testbench RAM
        -> memory response
        -> RTL architectural state

The resulting states are compared.

### Verified Architectural State

The current RTL2 differential workload compares:

    2048 vector register words
    32 scalar register words

    16 vector predicate masks
    16 scalar predicates

    1024 global-memory words

    final PC
    final EXEC_MASK
    final reconvergence stack depth

The normal workload emits exactly:

    3 external memory requests

corresponding to:

    predicated VLOADX
    predicated VSTOREX
    unpredicated VLOADX

### Verified RTL2 Result

The initial RTL2 memory workload completes with:

    program words = 6
    Python architectural steps = 6
    external memory requests = 3

The RTL and Python golden model match across all compared register, predicate,
control and memory state.

The verified final control state remains:

    EXEC_MASK = 0xFFFFFFFF
    reconvergence depth = 0

The active-invalid directed workload also verifies:

    external memory requests = 0

before fault termination.

### Current Memory Model Limitations

A0-RTL2 does not yet model:

    memory coalescing hardware
    cache hierarchy hardware
    load/store queues
    multiple outstanding requests
    memory-level parallelism
    request replay
    cache misses
    TLBs
    virtual memory
    page faults
    memory ordering
    atomics
    synchronization
    DRAM channels
    physical memory controllers

The external testbench RAM is a verification model, not final GPU memory
hardware.

### Transaction Geometry Status

Although A0-SIM8 currently explores a provisional 32-byte memory transaction
segment, RTL2 does not freeze that transaction geometry.

RTL2 exposes exact active per-lane addresses.

A later RTL milestone may experimentally group those addresses into physical
memory transactions and compare alternative coalescing implementations.

### Architectural Status

A0-RTL2 establishes the first A0 synthesizable hardware path that crosses from:

    instruction execution

into:

    external architectural global memory

and returns load results while remaining differential-equivalent to the Python
golden model.

The current interface is a correctness-oriented architectural boundary.

Its physical width, buffering, transaction geometry and memory-system topology
remain unfrozen.

## A0-RTL3A Synthesizable Memory Coalescer

A0-RTL3A introduces the first synthesizable A0 memory-coalescing block.

This milestone is intentionally separated from the RTL2 wave-core memory
interface.

RTL3A first proves transaction-formation correctness independently before the
coalescer is inserted into the live wave-to-memory datapath.

### Input Model

The coalescer receives:

    logical lane mask
    per-lane word addresses

for one logical A0 wave.

The current logical wave size remains:

    32 lanes

Only lanes enabled in the input lane mask participate.

Inactive lanes:

    do not count as requests
    do not contribute unique words
    do not contribute memory transactions
    do not influence transaction segment discovery

### Experimental Transaction Geometry

The current RTL3A configuration uses:

    TRANSACTION_WORDS = 8

With 32-bit architectural words this corresponds to:

    8 words * 4 bytes
    = 32 bytes

A transaction segment is currently identified by:

    segment_id =
        word_address / TRANSACTION_WORDS

This matches the existing A0-SIM8 experimental coalescing model.

The 32-byte transaction size is not frozen.

It remains a provisional architecture-exploration parameter that may change
after RTL integration, synthesis, FPGA experiments and later PPA analysis.

### Coalescer Outputs

RTL3A reports:

    lane request count
    unique word count
    transaction count

and a deterministic list of:

    transaction segment IDs

Transaction segments are emitted in first-active-lane discovery order.

This deterministic ordering exists primarily to support exact Python-to-RTL
differential verification.

It is not yet a requirement for the final physical memory system.

### Duplicate Word Handling

Multiple active lanes may request the same architectural word.

Such a pattern contributes:

    one unique word

but may represent multiple logical lane requests.

Example:

    32 active lanes
    all request the same word

produces:

    lane requests = 32
    unique words = 1
    transactions = 1

This broadcast behavior is verified.

### Contiguous Access

For the current experimental eight-word transaction geometry:

    lane 0  -> word 0
    lane 1  -> word 1
    ...
    lane 31 -> word 31

forms four transactions:

    segment 0
    segment 1
    segment 2
    segment 3

Therefore the verified result is:

    contiguous transactions = 4

### Strided Access

A stride of eight words causes each logical lane to access a different
transaction segment.

For a full 32-lane wave:

    address[lane] =
        lane * 8

the verified result is:

    transactions = 32

This demonstrates the expected contrast between contiguous and highly strided
memory access.

### Masked Access

RTL3A explicitly verifies that inactive lanes do not affect coalescing.

Test vectors include masked lanes containing deliberately extreme address
values.

Those inactive addresses do not alter:

    lane request count
    unique word count
    transaction count
    transaction segment list

### Differential Verification

A0-RTL3A is verified against the existing Python A0-SIM8 golden coalescing
model.

For each test case:

    lane mask
    per-lane word addresses

are supplied independently to:

    Python coalesce_word_addresses()

and:

    synthesizable SystemVerilog coalescer

The verifier compares:

    lane request count
    unique word count
    transaction count
    deterministic segment list

### Directed Cases

The current RTL3A regression includes five directed patterns:

    contiguous
    stride-eight
    first-sixteen-lanes masked access
    same-address broadcast
    duplicate words across multiple segments

### Randomized Differential Verification

In addition to directed cases, RTL3A executes:

    64 deterministic randomized cases

using a fixed random seed.

Random cases vary:

    lane masks
    word addresses
    duplicate addresses
    broadcast-like patterns
    transaction distribution

The fixed seed makes failures reproducible.

### Verified Result

The current verification set contains:

    directed cases = 5
    randomized cases = 64
    total cases = 69

All 69 cases match the Python golden model.

Verified reference results include:

    contiguous transactions = 4
    stride-eight transactions = 32
    broadcast unique words = 1
    broadcast transactions = 1

The deterministic transaction segment list also matches for every case.

### Synthesizability Status

The coalescer is written as synthesizable SystemVerilog.

The current implementation prioritizes architectural correctness and
differential verification over physical efficiency.

Its present combinational search structure is not a commitment to the final
high-performance GPU implementation.

Future versions may use different hardware structures such as:

    parallel comparison networks
    hierarchical grouping
    lane subsets
    staged coalescing
    transaction queues
    banked request collectors

while preserving equivalent architectural transaction formation.

### RTL3A Limitations

RTL3A is currently an isolated coalescing block.

It is not yet inserted between:

    A0 wave core

and:

    external memory system

Therefore RTL3A does not yet change the RTL2 request/response execution path.

It also does not currently implement:

    cache-line lookup
    load/store queues
    multiple outstanding transactions
    replay
    MSHRs
    memory ordering
    atomics
    virtual memory
    physical memory channels

### Next Integration Step

A subsequent RTL milestone will connect:

    RTL2 per-lane memory request
        -> RTL3A coalescer
        -> physical transaction stream
        -> memory service layer

That integration will turn coalescing from an independently verified function
into part of the live A0 global-memory datapath.

### Architectural Status

A0-RTL3A establishes differential equivalence between:

    A0-SIM8 memory coalescing semantics

and:

    synthesizable RTL transaction formation

across directed and deterministic randomized workloads.

The transaction geometry remains experimental and unfrozen.

## A0-RTL3B Live Coalesced Memory Path

A0-RTL3B integrates the independently verified RTL3A memory coalescer into the
live RTL2 indexed global-memory execution path.

The RTL2 wave-core memory boundary remains architecturally intact.

The integration path is:

    wave core
        -> architectural per-lane memory request
        -> coalesced memory bridge
        -> RTL3A transaction formation
        -> serialized physical segment transactions
        -> external memory service
        -> load-response reconstruction
        -> wave-core architectural response

### Architectural Request vs Physical Transaction

RTL3B explicitly separates two concepts.

An architectural memory request is one logical VLOADX or VSTOREX operation
issued by a wave.

A physical transaction is one provisional memory segment produced after
coalescing the active lane addresses.

Therefore one architectural request may generate multiple physical
transactions.

This distinction is now observable and differentially verified in live RTL.

### Transaction Geometry

RTL3B currently uses the same experimental transaction geometry as SIM8 and
RTL3A:

    TRANSACTION_WORDS = 8

For 32-bit words:

    8 words = 32 bytes

The current segment identity remains:

    segment_id =
        word_address / TRANSACTION_WORDS

This geometry is experimental and unfrozen.

It is not a commitment to the final cache-line size, memory-controller burst
size, DRAM transaction size or commercial A0 memory subsystem.

### Bridge Operation

The current bridge accepts one complete wave-side architectural memory request.

It latches:

    request type
    active lane mask
    per-lane word addresses
    per-lane store data

The RTL3A coalescer then determines the unique physical segments required by
the active lanes.

RTL3B currently allows exactly one outstanding architectural memory request.

Its physical transactions are serviced serially.

The implementation therefore prioritizes correctness and observability rather
than final throughput.

### Load Response Reconstruction

A physical load transaction contains only the active lanes belonging to the
currently issued segment.

Returned data is accumulated across all physical transactions belonging to the
architectural load.

After the final segment completes, RTL3B emits one architectural response back
to the wave core.

Each logical lane therefore receives the value corresponding to its original
word address even when one architectural load is decomposed into several
physical transactions.

Same-word lane requests remain compatible with broadcast-style reconstruction.

### Store Operation

Store transactions use the same active-lane segment grouping.

The current live differential workload avoids ambiguous duplicate-address
active stores.

Final duplicate-store collision and lane-precedence semantics remain unfrozen
and require an explicit architectural decision before becoming part of the
permanent contract.

### Fault Semantics

The RTL2 wave core remains responsible for indexed architectural address
validation.

Inactive masked lanes do not participate in validation.

An invalid active lane faults before the architectural request escapes the wave
core.

The RTL3B fault differential verifies:

    architectural requests = 0
    physical transactions = 0

for an active invalid indexed memory access.

A physical transaction fault reported by the backend causes the complete
architectural request to fail.

### Live Differential Verification

The primary RTL3B differential reuses the RTL2 indexed-memory workload.

The workload contains three architectural memory operations.

With the current eight-word transaction geometry they form:

    first VLOADX:
        addresses 100..115
        transactions = 3

    VSTOREX:
        addresses 316..331
        transactions = 3

    second VLOADX:
        addresses 190..221
        transactions = 5

Therefore:

    architectural memory requests = 3
    physical transactions = 11

The transaction count is independently calculated through the Python SIM8
`coalesce_word_addresses` golden model.

The live RTL result matches:

    architectural requests = 3
    physical transactions = 11

The differential also compares:

    2048 vector-register words
    32 scalar registers
    16 vector predicate registers
    16 scalar predicate registers
    1024 global-memory words
    EXEC_MASK
    program counter
    reconvergence depth

The normal RTL3B workload therefore verifies both architectural state and
physical transaction formation through the integrated datapath.

### Maximum Transaction-Count Boundary

RTL3A already established that a full 32-lane stride-eight access produces:

    32 physical transactions

A0-RTL3B additionally executes this case through the live bridge.

The boundary program performs one full-wave VLOADX with:

    address[lane] =
        lane * TRANSACTION_WORDS

With the current configuration each lane belongs to a different segment.

Verified result:

    architectural memory requests = 1
    physical transactions = 32

All 32 transactions complete successfully.

The final load result matches Python across all 2048 vector-register words,
and the complete 1024-word global-memory image remains equal.

This regression specifically protects the bridge's maximum transaction-count
index boundary.

### Current Timing Interpretation

The current bridge serializes physical transactions and supports only one
outstanding architectural request.

Observed cycle counts are therefore testbench and current microarchitecture
results only.

They are not performance predictions and are not frozen architectural latency
values.

Future implementations may pipeline or overlap transaction generation,
issuance and completion while preserving the same architectural behavior.

### RTL3B Limitations

RTL3B does not yet implement a final GPU memory hierarchy.

Not yet defined or implemented:

    multiple outstanding wave memory requests
    nonblocking transaction issue
    request queues
    load/store queues
    MSHRs
    replay
    cache hierarchy integration
    cache misses or writeback
    memory ordering model
    atomics
    TLB or virtual memory
    DRAM scheduling
    memory channels
    memory compression
    final store collision precedence
    final transaction geometry
    final arbitration policy
    final latency or throughput

The current serialized bridge is a correctness-first integration layer.

### Architectural Status

A0-RTL3B establishes the first live synthesizable A0 path in which:

    indexed wave memory instruction
        -> active per-lane addresses
        -> synthesizable coalescing
        -> physical segment transactions
        -> memory service
        -> reconstructed wave response

is executed end-to-end.

The Python architectural simulator and SIM8 coalescing model remain the golden
references for this milestone.

Transaction geometry, scheduling policy and physical implementation remain
experimental and unfrozen.

## A0-RTL4A Parameterized Physical Lane Sequencer

A0-RTL4A introduces a standalone synthesizable physical-lane sequencer.

The purpose of this milestone is to separate the architectural logical wave
width from a provisional physical SIMD execution width before integrating that
behavior into the live wave core.

The architectural wave remains:

    WAVE_SIZE = 32

The physical execution width is independently parameterized:

    PHYSICAL_LANES

The current project direction uses eight physical lanes as a provisional
implementation target:

    PHYSICAL_LANES = 8

This value remains experimental and unfrozen.

### Logical Wave and Physical Beats

A logical 32-lane vector operation may require multiple physical execution
beats.

The mapping is:

    logical_lane =
        beat_index * PHYSICAL_LANES
        + physical_lane

For example:

    WAVE_SIZE = 32
    PHYSICAL_LANES = 8

produces:

    beat 0 -> logical lanes 0..7
    beat 1 -> logical lanes 8..15
    beat 2 -> logical lanes 16..23
    beat 3 -> logical lanes 24..31

The number of required physical beats is:

    ceil(WAVE_SIZE / PHYSICAL_LANES)

### Execution Masking

Each physical slot has two distinct validity concepts.

`physical_valid_mask` indicates that the slot maps to a real logical lane.

`physical_active_mask` additionally applies architectural execution masking:

    valid logical lane
    AND EXEC_MASK[logical_lane]
    AND (
        predicate disabled
        OR predicate_mask[logical_lane]
    )

The sequencer therefore preserves logical EXEC and vector-predicate semantics
while exposing only the currently serviced physical subset.

### Partial Final Beats

PHYSICAL_LANES does not need to divide WAVE_SIZE exactly.

For:

    WAVE_SIZE = 32
    PHYSICAL_LANES = 6

the sequencer produces six beats.

The final beat maps:

    physical slot 0 -> logical lane 30
    physical slot 1 -> logical lane 31
    physical slots 2..5 -> invalid

Only the first two physical slots are asserted in `physical_valid_mask`.

Values associated with invalid physical slots are not architectural state and
are treated as don't-care values.

### Handshake

The standalone sequencer accepts a logical vector-operation launch with
`start`.

While the logical operation is being physically traversed:

    busy = 1
    beat_valid = 1

Each beat exposes:

    beat_index
    physical_valid_mask
    physical_active_mask
    logical_lane mapping

After the final beat completes:

    busy = 0
    done = 1 for one cycle

`done` is therefore a logical-operation completion indication rather than a
per-physical-beat completion indication.

### Differential Verification

A0-RTL4A is differentially checked against an independent Python golden model.

Verified physical-width configurations:

    PHYSICAL_LANES = 32 -> 1 beat
    PHYSICAL_LANES = 16 -> 2 beats
    PHYSICAL_LANES = 8  -> 4 beats
    PHYSICAL_LANES = 6  -> 6 beats
    PHYSICAL_LANES = 4  -> 8 beats

The six-lane case deliberately verifies non-divisible physical width and the
partial final-beat valid mask.

For every configuration the differential checks:

    beat count
    physical-to-logical lane mapping
    physical valid mask
    EXEC masking
    optional predicate masking
    one-cycle completion behavior

Two execution-mask scenarios are exercised per physical-width configuration.

### Architectural Status

A0-RTL4A does not yet change execution inside `a0_wave_core`.

The existing wave core continues to execute its vector operations across all
logical lanes inside one architectural instruction implementation.

A0-RTL4A instead establishes and verifies the physical-lane sequencing
primitive independently before live integration.

This avoids changing vector execution, scalar execution, memory behavior,
control flow and PC semantics simultaneously.

### Next Integration Step

A future integration milestone will use the sequencer in the live wave core.

That integration must ensure that:

    vector operations execute only the current physical beat
    all beats complete before the logical instruction retires
    PC advances exactly once per logical instruction
    scalar operations execute exactly once
    vector predicates preserve logical-lane semantics
    SIMT EXEC_MASK semantics remain unchanged
    memory operations preserve architectural behavior
    control-flow and reconvergence behavior remain unchanged

Python architectural behavior will remain the golden reference.

### Unfrozen Decisions

The following remain experimental:

    PHYSICAL_LANES
    physical SIMD width
    issue width
    beat scheduling policy
    pipeline depth
    instruction latency
    vector functional-unit organization
    register-file banking
    operand collection
    writeback organization
    physical lane sharing
    multi-wave interleaving policy

A0-RTL4A establishes correctness of logical-to-physical lane sequencing only.
It does not freeze the final GPU microarchitecture.

## A0-RTL4B - Live Physical Vector Execution

A0-RTL4B integrates the RTL4A physical-lane sequencer into the live
`a0_wave_core` execution path.

The architectural wave size remains 32 logical lanes.

The physical SIMD width is parameterized through:

    PHYSICAL_LANES

The core default is:

    PHYSICAL_LANES = WAVE_SIZE

This default preserves source/configuration compatibility with earlier RTL
verification environments. The dedicated RTL4B differential verifier
instantiates:

    WAVE_SIZE = 32
    PHYSICAL_LANES = 8

to prove that one architectural vector instruction is executed across
multiple physical beats.

### Sequenced Instructions

RTL4B physically sequences the following vector integer operations:

    VADD
    VSUB
    VMUL
    VAND
    VOR
    VXOR

and the vector comparisons:

    VCMP_EQ
    VCMP_LT
    VCMP_LE

Vector arithmetic respects EXEC_MASK and optional vector predication.

The comparison operations preserve their existing EXEC_MASK semantics.

Scalar operations and control-flow operations remain logical
single-execution operations in RTL4B.

### Physical Lane Mapping

For each physical beat:

    logical_lane =
        beat_index * PHYSICAL_LANES
        + physical_lane

Only valid logical lanes participate.

The lane sequencer continues to support physical widths that do not evenly
divide the architectural wave size. Tail validity and non-divisible-width
behavior remain verified by RTL4A.

### Architectural PC Retirement

A sequenced vector instruction retains one architectural PC for its entire
physical execution.

The PC is held while physical beats execute.

After the final beat completes, the logical vector instruction retires once
and the PC advances exactly once.

For the dedicated 32-lane / 8-physical-lane RTL4B verification case:

    one logical vector instruction
        -> four physical beats
        -> one architectural retirement

The verified RTL4B workload executes:

    10 logical vector instructions
    40 physical beats
    10 architectural retirements

with no PC-hold or retirement-PC violations.

### Global Memory Boundary

RTL4B does not physically slice VLOADX or VSTOREX requests.

Indexed global-memory operations remain wave-wide at the interface to the
RTL3B coalesced memory path.

This is intentional: the memory coalescer must observe all active logical
lane addresses of the wave together.

The existing RTL3B contracts remain unchanged and verified:

    3 architectural memory requests
        -> 11 physical transactions

and the maximum-transaction boundary:

    1 architectural memory request
        -> 32 physical transactions

Both continue to match the SIM8 transaction model.

### Pause Semantics

The lane sequencer has an `advance_enable` input.

The live wave core connects sequencing progress to `run_enable`.

When `run_enable` is deasserted, an in-progress physical vector instruction
does not advance to another beat. Execution resumes from the preserved beat
state when `run_enable` is asserted again.

### Current Timing Interpretation

RTL4B establishes correctness of physical execution sequencing.

The current control protocol contains explicit launch and completion cycles.
Therefore the current provisional sequenced-instruction cycle cost is:

    ceil(WAVE_SIZE / PHYSICAL_LANES) + 2

For example:

    PHYSICAL_LANES = 32 -> 3 cycles
    PHYSICAL_LANES = 8  -> 6 cycles
    PHYSICAL_LANES = 6  -> 8 cycles

This control overhead is not a frozen performance model and is not a claim
about final GPU throughput.

Future pipelining, issue logic, scoreboard behavior, lane sharing and
retirement implementation may overlap or restructure these phases.

The physical SIMD width itself also remains experimental and is not frozen.

### Backward Verification Compatibility

Because `a0_wave_core` now instantiates `a0_lane_sequencer`, existing
core-based RTL differential verifier build lists include
`a0_lane_sequencer.sv` as a source dependency.

This is a verification-harness dependency update rather than an
architectural behavior change.

RTL0 through RTL3B architectural differential comparisons continue to pass
after RTL4B integration.

### RTL4B Verification

The dedicated RTL4B verification proves:

    PHYSICAL_LANES = 8
    logical vector instructions = 10
    physical beats = 40
    vector retirements = 10

    VECTOR_PC_HOLD = PASS
    VECTOR_RETIREMENT_MATCH = PASS
    PHYSICAL_BEAT_RATIO = PASS

and compares the resulting RTL architectural state against the Python golden
model:

    2048 vector register words
    32 scalar register words
    16 vector predicate masks

The differential result is:

    RTL4B_DIFF = PASS

RTL4B therefore establishes the first live A0 wave-core path in which a
logical 32-lane vector instruction is executed by a narrower parameterized
physical SIMD implementation while preserving architectural state and
single-instruction retirement semantics.

## A0-RTL5A - Vector Execution Pipeline Foundation

A0-RTL5A separates architectural vector-instruction issue from
physical SIMD beat execution.

### Execution ownership

Sequenced vector instructions are captured once into explicit
in-flight instruction state:

- opcode
- flags
- destination register
- source registers
- predicate index
- architectural instruction PC

After issue, physical vector execution consumes the captured state
rather than repeatedly depending on live program_mem[pc] decode.

The execution structure is:

    Fetch / Decode
          |
          v
    Vector Issue / Instruction Latch
          |
          v
    Physical Beat Execution
          |
          v
    Architectural Retirement

### Dedicated vector execution stage

vector_waiting identifies ownership of an issued vector instruction
by the physical vector execution stage.

The sequenced operations remain:

- VADD
- VSUB
- VMUL
- VAND
- VOR
- VXOR
- VCMP_EQ
- VCMP_LT
- VCMP_LE

The duplicated RTL4B per-opcode launch/beat/completion state machines
were replaced by grouped issue, explicit instruction latching, one
shared physical execution engine, and explicit architectural
retirement.

### PC and retirement contract

The architectural PC remains fixed at the captured vector instruction
PC while physical beats execute.

After the final physical beat, exactly one architectural retirement
advances the PC to the captured instruction PC plus one.

RTL4B compatibility remains:

    PHYSICAL_LANES=8
    VECTOR_INSTRUCTIONS=10
    PHYSICAL_BEATS=40
    VECTOR_RETIREMENTS=10
    VECTOR_PC_HOLD=PASS
    VECTOR_RETIREMENT_MATCH=PASS
    PHYSICAL_BEAT_RATIO=PASS

At A0-RTL5A completion, the RTL4B reference workload remained at 63 cycles. RTL5A therefore
changes execution ownership without intentionally changing the
existing provisional timing contract.

### Pause semantics

run_enable=0 freezes an in-flight physical vector sequence.

While paused:

- vector ownership remains active
- physical beat index does not advance
- architectural PC remains fixed
- no early destination-register write occurs

### Live-decode independence proof

The RTL5A verifier issues a predicated VADD and pauses the core while
that instruction is still in flight.

The same program-memory location is then overwritten through the
normal program-write interface with VXOR.

The live decoder observes VXOR while the captured execution state
continues to own the original VADD.

After resume, the core completes the captured predicated VADD and
retires it exactly once.

The verifier proves:

    ISSUED_OPCODE_LATCHED=PASS
    ISSUED_METADATA_LATCHED=PASS
    PROGRAM_MEMORY_MUTATION=PASS
    LIVE_DECODE_INDEPENDENCE=PASS
    PAUSE_STATE_STABLE=PASS
    NO_EARLY_VECTOR_WRITE=PASS
    VECTOR_PC_HOLD=PASS
    SINGLE_RETIREMENT=PASS
    RTL5A_DIFF=PASS
    LATCHED_EXECUTION_OPCODE=VADD
    MUTATED_LIVE_OPCODE=VXOR

### Memory boundary

VLOADX and VSTOREX remain on the existing wave-wide memory path.

RTL5A does not split architectural global-memory requests into
physical-lane requests, preserving the RTL3B full-wave coalescer
boundary.

### Scope and non-goals

A0-RTL5A establishes execution-stage ownership and pipeline
boundaries. It does not freeze or claim final:

- issue width
- execution latency
- pipeline depth
- physical SIMD width
- scoreboard structure
- register-file porting
- bypass or forwarding policy
- multi-wave scheduling
- throughput
- final performance

Those remain subjects for later RTL milestones and implementation
evidence.

## A0-RTL5B - Scoreboard and Register Hazard Tracking

A0-RTL5B introduces explicit register-dependency classification and
scoreboard ownership for the vector execution path.

The milestone establishes the structural foundation required for
future decoupled issue, overlapping execution, latency hiding and
multi-wave scheduling.

### Scoreboard state

The RTL5B scoreboard maintains independent busy state for:

- 64 vector registers
- 16 vector predicate registers

The scoreboard currently detects:

- vector RAW dependencies
- vector WAW dependencies
- predicate RAW dependencies
- predicate WAW dependencies

RAW means that a candidate instruction attempts to read a destination
that is still owned by an in-flight operation.

WAW means that a candidate instruction attempts to reserve a
destination that is already owned by an in-flight operation.

WAR tracking is intentionally outside the RTL5B contract because the
current wave core does not yet contain overlapping operand-read and
writeback stages that require WAR interlocking.

### Reservation and release

A successful issue may reserve:

- a vector destination register
- a predicate destination register

Architectural completion releases the corresponding reservation.

The standalone scoreboard also defines release-before-reserve
ordering when both operations target the same destination in one
clock cycle.

Therefore a new reservation remains busy after that clock edge.

Same-cycle retirement-to-issue bypass policy is not frozen by this
milestone.

### Dependency classifier

A synthesizable instruction dependency classifier converts decoded
A0 instruction fields into scoreboard read/write sets.

The current classification contract includes:

Vector ALU operations:

- VADD
- VSUB
- VMUL
- VAND
- VOR
- VXOR

These operations:

- read vector src0
- read vector src1
- write vector dst
- optionally read the selected vector predicate when flags[0] enables
  predication

Vector compares:

- VCMP_EQ
- VCMP_LT
- VCMP_LE

These operations:

- read vector src0
- read vector src1
- write the predicate selected by pred_index

The current VCMP execution contract uses EXEC rather than an input
predicate, so flags[0] does not create a predicate-source dependency
for VCMP.

VLOADX classification:

- scalar src0 is the scalar address base and is outside the current
  vector/predicate scoreboard
- vector src1 is the per-lane address offset
- vector dst is the load destination
- pred_index is an optional predicate source when flags[0] is enabled

VSTOREX classification:

- scalar src0 is the scalar address base and is outside the current
  vector/predicate scoreboard
- vector src1 is the per-lane address offset
- vector src2 is store data
- pred_index is an optional predicate source when flags[0] is enabled

SPLIT consumes the selected vector predicate.

Scalar register and scalar-predicate dependency tracking remain
outside the RTL5B vector/predicate scoreboard contract.

### Live wave-core integration

The live A0 wave core now connects the dependency classifier and
scoreboard to the sequenced vector execution path.

The issue structure is:

    Decode
      |
      v
    Dependency Classifier
      |
      v
    Scoreboard Query
      |
      +---- hazard ----> hold architectural PC
      |
      +---- ready -----> Vector Issue
                           |
                           v
                     Destination Reserve
                           |
                           v
                     Physical Beat Execution
                           |
                           v
                     Architectural Retirement
                           |
                           v
                     Destination Release

scoreboard_query_valid is asserted only when the sequenced vector
front end is eligible to issue:

- run_enable is asserted
- the core is not halted
- no architectural memory request is waiting
- no sequenced vector instruction is already in flight
- the live opcode is a sequenced vector operation

vector_issue_fire requires both an eligible query and scoreboard
issue permission.

The physical lane sequencer starts from the same vector_issue_fire
condition used by architectural issue.

Therefore a scoreboard hazard cannot launch physical SIMD execution
while architectural issue remains stalled.

### Live destination ownership

For vector ALU instructions, the decoded vector destination is
reserved on issue.

For VCMP instructions, the decoded predicate destination is reserved
on issue.

Reservation remains active through all physical SIMD beats.

At vector_seq_done, the captured in-flight instruction metadata
determines which reservation is released.

The release therefore follows RTL5A instruction ownership rather than
live program-memory decode.

Predicates used only as predication sources are never reserved as
destinations.

### Current serialization boundary

RTL5B does not introduce overlapping vector issue.

The current arbitration still gives an in-flight vector instruction
exclusive execution ownership through vector_waiting.

As a result, another sequenced vector instruction does not reach the
live scoreboard query while the previous instruction remains in
flight.

Therefore the live RTL5B integration proves:

- correct dependency classification
- real destination reservation
- reservation lifetime through execution
- release at architectural retirement
- issue gating
- no false stalls

It does not yet claim that a dependent second instruction can arrive
concurrently and demonstrate a live RAW or WAW stall against an
older executing vector instruction.

RAW and WAW classification itself is directly proven by the
standalone scoreboard and classifier integration tests.

Real overlapping issue, back-to-back dependency stalls, forwarding,
bypass behavior and latency hiding require a later execution-front-end
milestone.

### Memory and control boundary

VLOADX, VSTOREX and SPLIT are classified by the standalone dependency
classifier.

Their live wave-core reservation/issue paths remain outside the RTL5B
Phase 3 integration.

The existing wave-wide RTL3B memory/coalescer boundary is therefore
unchanged.

### Verification

The standalone scoreboard verifier proves:

    RTL5B_SCOREBOARD_TB=PASS
    VECTOR_RAW_HAZARD=PASS
    VECTOR_WAW_HAZARD=PASS
    VECTOR_SRC2_RAW_HAZARD=PASS
    VECTOR_NO_FALSE_HAZARD=PASS
    PREDICATE_RAW_HAZARD=PASS
    PREDICATE_WAW_HAZARD=PASS
    RESERVATION_RELEASE=PASS
    RELEASE_RESERVE_SAME_CYCLE=PASS
    INVALID_QUERY_BLOCKED=PASS

The classifier verifier proves:

    RTL5B_CLASSIFIER_TB=PASS
    ALU_DEPENDENCY_CLASS=PASS
    PREDICATED_ALU_CLASS=PASS
    COMPARE_PREDICATE_DEST=PASS
    VLOADX_DEPENDENCY_CLASS=PASS
    VSTOREX_DEPENDENCY_CLASS=PASS
    SPLIT_PREDICATE_SOURCE=PASS
    CLASSIFIER_SCOREBOARD_RAW=PASS
    CLASSIFIER_SCOREBOARD_WAW=PASS
    CLASSIFIER_SCOREBOARD_PRED_RAW=PASS
    CLASSIFIER_SCOREBOARD_PRED_WAW=PASS
    UNTRACKED_OPCODE_BLOCKED=PASS

At A0-RTL5B completion, the live wave-core verifier proved:

    RTL5B_CORE_TB=PASS cycles=19 pc=4
    CORE_VECTOR_ISSUES=3
    CORE_VECTOR_RETIREMENTS=3
    VECTOR_DEST_RESERVATION=PASS
    PREDICATE_DEST_RESERVATION=PASS
    BUSY_HELD_UNTIL_RETIRE=PASS
    RETIRE_RELEASE=PASS
    PREDICATE_SOURCE_NOT_RESERVED=PASS
    CORE_FALSE_STALLS=0
    ARCHITECTURAL_RESULT_MATCH=PASS

### Backward compatibility

Existing wave-core verifier build lists now include:

- a0_scoreboard.sv
- a0_dependency_classifier.sv

This is required because a0_wave_core directly instantiates both
modules.

At A0-RTL5B completion, the architectural compatibility gates
remained unchanged.

In particular, the RTL4B reference workload at that milestone was:

    cycles=63
    PHYSICAL_LANES=8
    VECTOR_INSTRUCTIONS=10
    PHYSICAL_BEATS=40
    VECTOR_RETIREMENTS=10
    VECTOR_PC_HOLD=PASS
    VECTOR_RETIREMENT_MATCH=PASS
    PHYSICAL_BEAT_RATIO=PASS
    RTL4B_DIFF=PASS

RTL5A also continues to prove latched instruction ownership and
live-decode independence.

### Scope and non-goals

A0-RTL5B establishes dependency metadata and destination ownership.

It does not freeze or claim final:

- scoreboard organization
- scoreboard implementation size
- issue width
- pipeline depth
- WAR policy
- forwarding
- bypass policy
- retirement-to-issue bypass
- scalar dependency tracking
- scalar-predicate dependency tracking
- memory dependency tracking
- load/store ordering
- overlapping vector issue
- multi-wave scheduling
- latency hiding
- physical SIMD width
- register-file porting
- execution latency
- final throughput
- final GPU performance

These remain implementation and measurement subjects for later RTL
milestones.
## A0-RTL5C - Decoupled Pending Issue and Live Hazard Stalls

A0-RTL5C decouples dependency observation from the currently executing
sequenced vector instruction.

RTL5B established dependency classification and scoreboard ownership,
but its live wave-core integration remained serialized: another
sequenced vector instruction did not reach the live scoreboard while
the previous vector instruction remained in flight.

RTL5C adds a one-entry pending vector-instruction slot so that the next
sequenced vector instruction can be captured and classified while the
current vector instruction continues physical execution.

This is front-end decoupling rather than a second execution engine.
Only one sequenced vector instruction owns the physical lane sequencer
at a time.

### Pending instruction state

The live wave core maintains pending metadata for:

- opcode
- flags
- vector destination index
- vector src0 index
- vector src1 index
- vector src2 index
- predicate index
- architectural PC

When pending state is valid, the pending instruction takes priority as
the dependency-classifier candidate.

Therefore the classifier and scoreboard can inspect the next sequenced
vector instruction without replacing or mutating the metadata owned by
the currently executing instruction.

The pending slot captures only a safely addressable sequential
successor.

RTL5C does not define program-memory wraparound behavior when the
current instruction is at the end of the configured PROGRAM_WORDS
range.

The pending path also does not change the existing global-memory or
control-flow execution boundaries.

### Issue paths

The current live vector front end has three issue paths:

    direct_vector_issue_fire

A sequenced vector instruction issues directly from the architectural
front end when no older vector execution owns the sequencer and no
pending instruction has priority.

    pending_vector_issue_fire

A previously captured pending vector instruction issues after the
execution engine becomes available and the scoreboard reports that its
dependencies are ready.

    pending_handoff_fire

An independent pending instruction may become the next execution owner
on the same architectural completion edge that retires the previous
vector instruction.

The architectural vector issue event is the union:

    vector_issue_fire =
        direct_vector_issue_fire
        || pending_vector_issue_fire
        || pending_handoff_fire

Destination reservation is driven by that same issue event.

### Independent retirement handoff

An independent pending vector instruction may already be scoreboard
ready while an older vector instruction is still physically executing.

When the older instruction reaches vector_seq_done, the physical lane
sequencer is available for a new start.

If the pending instruction is dependency-free, RTL5C allows:

    older vector retirement
        +
    younger pending issue

on the same clock edge.

The dedicated RTL5C verifier proves this retirement-time handoff and
observes no dependency-specific bubble for the independent successor.

This does not imply multiple simultaneous physical vector executions.
Execution ownership transfers from the retiring instruction to the
pending instruction.

### Live RAW and WAW stalls

The pending instruction remains visible to the dependency classifier
and scoreboard while the producer remains in flight.

This allows the live core to demonstrate real scheduling stalls rather
than only standalone scoreboard classification.

The current RTL5C verification proves:

- vector RAW blocking
- vector WAW blocking
- predicate RAW blocking

For a dependent pending instruction, the producer destination is still
busy during the producer retirement observation window.

The current scoreboard has no retirement-to-issue combinational bypass.

Therefore the dependent instruction cannot use
pending_handoff_fire on that retirement edge.

The producer reservation is released on the completion edge, and the
pending dependent instruction becomes issuable on the following cycle.

The verified RTL5C implementation therefore observes exactly one
additional bubble for the directed vector RAW, vector WAW and
predicate RAW cases.

That one-cycle result is a property of the current implementation and
current no-bypass policy.

It is not an ISA timing guarantee and does not freeze the timing of a
future forwarding or retirement-bypass implementation.

### Predicate dependency behavior

The directed predicate dependency proof uses a vector compare as the
producer and a predicated vector ALU operation as the consumer.

The compare owns its predicate destination until retirement.

The pending predicated ALU instruction therefore observes a predicate
RAW hazard while that predicate destination remains busy.

The consumer does not hand off on the producer retirement edge.

After the predicate destination is released, the pending predicated
instruction issues on the following cycle.

Predicates used only as sources are still not reserved as destinations.

### Issue and retirement event semantics

Before RTL5C, some compatibility verifiers inferred instruction events
from transitions of vector_waiting.

That is no longer a valid general event definition.

A zero-bubble retirement handoff may keep:

    vector_waiting = 1

before and after the handoff edge.

Therefore vector_waiting is now interpreted as an execution-ownership
level rather than an issue or retirement pulse.

The live event definitions used by RTL5C verification are:

    vector_issue_fire
        instruction becomes the vector execution owner

    scoreboard_release_valid
        current vector instruction reaches architectural
        completion and releases its destination ownership

Compatibility verifiers that count vector issue and retirement now use
these explicit events rather than vector_waiting rising and falling
edges.

This preserves the architectural checks while allowing legal
back-to-back execution ownership.

### Compatibility verification

The RTL4B compatibility verifier was updated to observe explicit
issue/retirement events.

With RTL5C active, the reference workload verifies:

    RTL4B_TB=PASS cycles=56 pc=13
    PHYSICAL_LANES=8
    VECTOR_INSTRUCTIONS=10
    PHYSICAL_BEATS=40
    VECTOR_RETIREMENTS=10
    VECTOR_PC_HOLD=PASS
    VECTOR_RETIREMENT_MATCH=PASS
    PHYSICAL_BEAT_RATIO=PASS
    RTL4B_DIFF=PASS

The physical work therefore remains:

    10 logical vector instructions
    40 physical SIMD beats
    10 architectural vector retirements

while the microarchitectural cycle count changes because independent
retirement-time handoff removes serialization bubbles.

The RTL5B live-core verifier also uses explicit issue and retirement
events under RTL5C.

The current compatibility result is:

    RTL5B_CORE_TB=PASS cycles=18 pc=4
    CORE_VECTOR_ISSUES=3
    CORE_VECTOR_RETIREMENTS=3
    VECTOR_DEST_RESERVATION=PASS
    PREDICATE_DEST_RESERVATION=PASS
    BUSY_HELD_UNTIL_RETIRE=PASS
    RETIRE_RELEASE=PASS
    PREDICATE_SOURCE_NOT_RESERVED=PASS
    CORE_FALSE_STALLS=0
    ARCHITECTURAL_RESULT_MATCH=PASS
    RTL5B_CORE_INTEGRATION_GATE=PASS

A real predicate dependency is excluded from the false-stall metric.
A scoreboard block without a real dependency remains a verification
failure.

### RTL5C verification

The directed RAW verifier proves:

    RTL5C_TB=PASS cycles=18 pc=4
    PENDING_CAPTURE=PASS
    PENDING_METADATA_STABLE=PASS
    INDEPENDENT_PENDING_READY=PASS
    INDEPENDENT_RETIRE_HANDOFF=PASS
    RAW_PENDING_HAZARD=PASS
    RAW_RETIRE_HANDOFF_BLOCKED=PASS
    RAW_ISSUE_AFTER_RELEASE=PASS
    RAW_EXTRA_BUBBLE_CYCLES=1
    ARCHITECTURAL_RESULT_MATCH=PASS
    RTL5C_PHASE1_CORE_GATE=PASS
    LIVE_RAW_STALL=PASS
    INDEPENDENT_ZERO_BUBBLE_HANDOFF=PASS

The additional hazard verifier proves:

    RTL5C_PHASE2_TB=PASS cycles=40 pc=8
    VECTOR_ISSUES=7
    VECTOR_RETIREMENTS=7
    INDEPENDENT_HANDOFFS=3
    VECTOR_WAW_PENDING_HAZARD=PASS
    VECTOR_WAW_HANDOFF_BLOCKED=PASS
    VECTOR_WAW_ISSUE_AFTER_RELEASE=PASS
    WAW_EXTRA_BUBBLE_CYCLES=1
    PREDICATE_RAW_PENDING_HAZARD=PASS
    PREDICATE_RAW_HANDOFF_BLOCKED=PASS
    PREDICATE_RAW_ISSUE_AFTER_RELEASE=PASS
    PREDICATE_RAW_EXTRA_BUBBLE_CYCLES=1
    PHASE2_ARCHITECTURAL_RESULT_MATCH=PASS
    PHASE2_SCOREBOARDS_EMPTY=PASS
    RTL5C_PHASE2_HAZARD_GATE=PASS
    LIVE_VECTOR_WAW_STALL=PASS
    LIVE_PREDICATE_RAW_STALL=PASS

The complete RTL0 through RTL5C compatibility regression passes after
the event-observer update.

The Python golden-model regression also remains:

    53 tests
    OK

### Scope and non-goals

A0-RTL5C establishes a one-entry pending vector front end and live
dependency stalls against an executing vector instruction.

It does not freeze or claim final:

- pending queue depth
- instruction-window depth
- issue width
- number of physical execution engines
- scoreboard organization
- scoreboard implementation size
- forwarding topology
- retirement-to-issue bypass
- general bypass policy
- WAR policy
- scalar dependency tracking
- scalar-predicate dependency tracking
- live memory dependency scheduling
- load/store ordering
- multi-wave scheduling
- wave selection policy
- latency hiding policy
- physical SIMD width
- pipeline depth
- execution latency
- cycle counts
- final throughput
- final GPU performance

The observed zero-bubble independent handoff and one-bubble dependent
cases characterize this RTL5C implementation only.

Later milestones may change those timing results while preserving the
architectural dependency and ownership contracts established here.

---

## A0-RTL5D — Standalone issue-window scaffold

A0-RTL5D introduced a standalone, parameterized instruction-window
experiment in `rtl/core/a0_issue_queue.sv`.

The scaffold stores decoded instruction metadata and performs
oldest-ready selection among resident entries.  It is intentionally
**not instantiated by `a0_wave_core.sv`**.  RTL5D therefore does not
change the live RTL5C datapath or retirement contract.

The first widened working-tree interface added:

- 6-bit vector register indices
- opcode and flags metadata
- src2 metadata
- vector-predicate index metadata
- issue-side metadata propagation
- a 64-bit vector busy-state input

A verification audit found that the historical RTL5D testbench still
instantiated the older interface.  With global `-Wno-fatal`, Verilator
reported missing pins and width expansion warnings while the driver
still emitted a PASS marker.  The widened RTL5D contract was therefore
not fully verified despite the historical completion tag.

The same audit also found that the first widened readiness expression
re-derived dependency semantics directly from encoded register fields.
That created four correctness defects:

1. unused src2 fields could create false vector RAW dependencies;
2. scalar fields such as VLOADX src0 could alias vector busy state;
3. vector destination WAW was not checked;
4. vector-predicate RAW/WAW was not checked.

These findings are closed by RTL5E rather than retroactively redefining
the historical RTL5D milestone.

### RTL5D scope and non-goals

RTL5D is a standalone scheduling-structure experiment.  It does not
freeze or claim final:

- integration into the live wave core
- queue placement in a multi-wave design
- queue depth
- wave scheduler policy
- issue width
- dependency ownership
- age/ordering representation
- scalar dependency tracking
- scalar-predicate dependency tracking
- memory ordering
- out-of-order retirement
- register renaming


## A0-RTL5E — Verification integrity and queue contract correction

RTL5E hardens the issue-window contract before any multi-wave scaling.
Its central rule is:

> Dependency semantics are classified once and stored as
> enable-qualified metadata.  The queue does not infer whether an
> encoded field is a vector source, scalar source, destination, or
> predicate dependency.

The queue now stores these dependency-enable bits with each entry:

- vector src0/src1/src2 enable
- vector destination enable
- vector-predicate source enable
- vector-predicate destination enable

Readiness is evaluated against vector and vector-predicate busy-state
snapshots only when the corresponding enable bit is asserted.  This
preserves `a0_dependency_classifier.sv` as the opcode-semantics source
of truth and preserves `a0_scoreboard.sv` as the owner of dependency
state.

The RTL5E standalone queue therefore checks:

- vector RAW on enabled vector source operands
- vector WAW on enabled vector destinations
- vector-predicate RAW on enabled predicate sources
- vector-predicate WAW on enabled predicate destinations

Scalar S-register and scalar-predicate Q-register dependencies remain
outside this milestone because the current RTL5B classifier/scoreboard
contract does not expose those classes.

### Compact wrap-safe ordering

The previous 64-bit monotonic age field is replaced by a local rank of
`$clog2(DEPTH)` bits.

The ranks are not allowed to wrap.  Instead, age 0 is always the oldest
resident entry and ranks younger than an issued entry collapse by one
on issue.  A new dispatch receives the youngest resident rank.  This
keeps ordering state bounded by queue depth without introducing the
wrap-around ambiguity of a truncated monotonic counter.

### Full-queue handoff

When the queue is full and the selected entry is accepted, dispatch may
reuse the issuing physical slot on the same clock edge.  This prevents
an avoidable front-end bubble at full occupancy while preserving local
age order.

### Verification integrity

Every RTL Python driver that keeps global `-Wno-fatal` now explicitly
promotes these interface-integrity diagnostics to hard errors:

- `PINMISSING`
- `WIDTHEXPAND`

This preserves existing intentional warning suppressions while making
an unconnected widened interface impossible to pass silently again.

The directed RTL5E queue test covers:

- full metadata propagation
- unused-src2 false-dependency regression
- scalar/vector alias regression
- vector WAW block/release
- vector-predicate RAW block/release
- vector-predicate WAW block/release
- oldest-ready bypass and re-prioritization
- full-queue backpressure
- same-cycle issue/dispatch refill

`sim/a0_queue_model.py` is the standalone queue golden model.  It uses
the existing simulator's `timing_sources()` and
`timing_destinations()` as the independent architectural dependency
reference for vector and vector-predicate classes.

`tests/run_rtl5e_queue_diff.py` generates a deterministic randomized
stream containing at least 10,000 accepted instructions and compares
cycle-by-cycle RTL queue selection and issue metadata against that
model.

### RTL5E scope and non-goals

RTL5E deliberately does **not** change:

- `a0_wave_core.sv`
- `a0_scoreboard.sv`
- `a0_dependency_classifier.sv`
- `a0_lane_sequencer.sv`
- memory RTL
- A0 ISA encoding
- architectural simulator semantics

It also does not freeze or claim final:

- multi-wave scheduling
- per-wave buffer depth
- scheduler policy
- instruction-level reordering policy
- WAR handling for a deeper reorder window
- scalar dependency tracking
- scalar-predicate dependency tracking
- register-file banking
- operand collection
- memory-level parallelism
- final GPU throughput or performance

The intended scaling direction remains to evolve the verified
wave-local pending-buffer mechanism into a deeper per-wave instruction
buffer and then place wave selection above replicated wave contexts.
RTL5E only establishes a correct reusable queue contract for that
future work.

---

## A0-RTL6 — Banked VRF and Operand Delivery Foundation

RTL6 begins the register-delivery scaling work without changing the live wave-core datapath.

Standalone blocks:

- `rtl/core/a0_regfile_banked.sv`
- `rtl/core/a0_operand_collector.sv`

The reference configuration uses four register banks and physical-beat storage aligned with `PHYSICAL_LANES`. The banked RF provides three logical source request ports, one-cycle read responses, explicit bank-conflict backpressure, one masked writeback port, and a defined same-address read/write merged-bypass policy.

The operand collector holds one instruction beat, retries conflicting source reads, captures returned operands, preserves completed data under backpressure, and supports same-edge completed-result consumption plus replacement-request acceptance.

The data array is intentionally not reset, preserving the path to SRAM/register-file macro inference. The current flat `vector_regs` array remains live until a later integration gate proves architectural equivalence.

**RTL6 foundation is not multi-wave integration.** Wave-scoped physical register allocation, fair multi-wave bank arbitration, multiple writeback clients, compiler bank-aware allocation, and register-file caching remain future work.

Full rationale, port contracts, non-goals, and verification are documented in:

`docs/architecture/A0_RTL6_BANKED_RF.md`

Required pre-commit gate:

```text
python3 tests/run_rtl6_foundation_gate.py
```

No RTL6 tag is valid until that command passes on the project Verilator/Python environment.

---

## A0-RTL6B — Live banked vector operand integration

RTL6B connects the verified RTL6 banked vector register file and operand
collector to the live sequenced vector execution path.

Key contract changes:

- sequenced VADD/VSUB/VMUL/VAND/VOR/VXOR and VCMP source operands come from the
  banked VRF through the collector, not from live `vector_regs` reads;
- the lane sequencer holds its current beat until the collector returns a
  complete operand set;
- classifier source/destination enable bits are latched with the issued
  instruction and drive both collection and scoreboard release semantics;
- vector ALU writes are mirrored to both the banked VRF and the transitional
  architectural `vector_regs` shadow;
- successful VLOADX responses are serialized into the banked VRF before issue
  resumes, preserving load-to-ALU coherence;
- indexed memory address/data reads remain on the legacy shadow in this phase.

The full design and verification contract are documented in
`docs/architecture/A0_RTL6B_LIVE_INTEGRATION.md`.

RTL6B deliberately does not remove the shadow register array, add multi-wave
physical allocation, or implement the final non-blocking LSU.
