\# A0 GPU ISA Specification



Version: 0.1

Status: Experimental



\## Instruction Width



A0-SIM1 uses a fixed 64-bit base instruction.



Future architectural generations may add 128-bit extended instructions.



\## Base 64-bit Encoding



Bits:



63..56  OPCODE      8 bits

55..52  FLAGS       4 bits

51..46  DST         6 bits

45..40  SRC0        6 bits

39..34  SRC1        6 bits

33..28  SRC2        6 bits

27..24  PRED        4 bits

23..0   IMM24      24 bits



Layout:



\[ OPCODE | FLAGS | DST | SRC0 | SRC1 | SRC2 | PRED | IMM24 ]



\## Registers



Vector:

V0-V63



Scalar:

S0-S31



Predicate:

P0-P15



\## Initial Opcodes



0x00 NOP



0x01 VADD

0x02 VSUB

0x03 VMUL

0x04 VAND

0x05 VOR

0x06 VXOR



0x20 FADD

0x21 FSUB

0x22 FMUL

0x23 FFMA



0x40 SADD

0x41 SSUB



0x50 VLOAD

0x51 VSTORE



0x60 VCMP\_EQ

0x61 VCMP\_LT

0x62 VCMP\_LE



0x70 JMP

0x71 BRA



0xFF HALT



\## SIMT Model



Initial logical wave size:



32 threads



Every wave owns an EXEC\_MASK.



Predicate registers contain one predicate bit per thread.



An instruction executes for:



EXEC\_MASK AND optional predicate mask



\## First Binary Program



VADD   V3, V1, V2

VMUL   V4, V3, V5

VSUB   V6, V4, V7

VSTORE V6, 0

HALT



\## Design Rule



This encoding is not permanently frozen.



Before freezing the ISA it must be evaluated through:



\- assembler implementation

\- software simulation

\- compiler experiments

\- RTL implementation

\- synthesis

\- FPGA resource measurements

\- performance measurements


## A0-SIM3 Experimental Structured Divergence

A0-SIM3 introduces an experimental structured SIMT control-flow mechanism.

Experimental opcodes:

    0x72 SPLIT
    0x73 ELSE
    0x74 JOIN

These instructions are not considered permanently frozen ISA.

### SPLIT

Example:

    SPLIT P0

The current EXEC_MASK is saved as the parent mask.

Two masks are derived:

    THEN_MASK = PARENT_MASK AND P0
    ELSE_MASK = PARENT_MASK AND NOT P0

Execution continues with:

    EXEC_MASK = THEN_MASK

A reconvergence-stack frame stores:

    parent EXEC_MASK
    deferred ELSE mask
    ELSE state

### ELSE

ELSE activates the deferred ELSE mask belonging to the most recent SPLIT:

    EXEC_MASK = ELSE_MASK

An ELSE without a matching SPLIT is invalid.

A duplicate ELSE for the same SPLIT is invalid.

### JOIN

JOIN removes the most recent reconvergence frame and restores:

    EXEC_MASK = PARENT_MASK

A JOIN without a matching SPLIT is invalid.

### SIM3 Validation Program

The initial validation program implements the equivalent of:

    if (thread_id < 16)
        value = value + 7;
    else
        value = value * 2;

Initial value:

    value = 100

Expected results:

    threads 0-15  = 107
    threads 16-31 = 200

After JOIN:

    reconvergence stack must be empty
    EXEC_MASK must contain all active threads

### Architectural Status

SPLIT / ELSE / JOIN are research instructions used to validate:

- divergence
- per-path execution masks
- reconvergence
- nested-control-flow feasibility

The final production GPU may instead encode control flow using branch instructions,
compiler-generated reconvergence metadata, explicit mask operations, or another
mechanism selected after compiler, RTL, FPGA, performance and PPA evaluation.

## A0-ASM1 / A0-SIM4 PC-Relative Control Flow

A0-ASM1 introduces symbolic labels and two-pass assembly.

A0-SIM4 introduces the first real program-counter-changing instruction.

### Two-Pass Assembly

Pass 1:

    scan source
    assign instruction PCs
    collect label -> PC mappings

Pass 2:

    parse instructions
    resolve symbolic labels
    calculate relative offsets
    encode machine instructions

Example:

    VADD V3, V1, V2
    JMP store
    VMUL V3, V3, V5

store:
    VSTORE V3, 0
    HALT

### JMP

Opcode:

    0x70 JMP

JMP uses a signed 24-bit PC-relative displacement stored in IMM24.

The architectural target is calculated relative to the instruction following
the JMP:

    TARGET_PC = NEXT_PC + SIGN_EXTEND(IMM24)

Equivalently during assembly:

    OFFSET = TARGET_PC - (CURRENT_PC + 1)

### Forward Jump Example

If:

    JMP is at PC 1
    target is at PC 3

then:

    NEXT_PC = 2
    OFFSET = 3 - 2
    OFFSET = +1

IMM24 contains:

    0x000001

### Backward Jump Example

If:

    JMP is at PC 1
    target is at PC 0

then:

    NEXT_PC = 2
    OFFSET = 0 - 2
    OFFSET = -2

Signed 24-bit two's-complement representation:

    0xFFFFFE

### Range

Signed IMM24 jump displacement range:

    -8388608 through +8388607 instructions

This range is provisional.

### Uniform Control Flow

JMP is currently a uniform wave-level control-flow instruction.

It changes the single wave program counter and does not depend on per-thread
predicate state.

Divergent per-thread control flow remains handled experimentally by:

    SPLIT
    ELSE
    JOIN

Uniform conditional branches and compiler-managed divergent branches will be
designed separately.

### Execution Safety

The simulator rejects JMP targets outside instruction memory.

The simulator also has a maximum instruction-count guard to detect accidental
infinite loops during architecture development and testing.

### Architectural Status

The label syntax, IMM24 displacement size, and exact branch architecture remain
experimental until compiler, RTL, FPGA and PPA evaluation.

## A0-SIM5 Scalar Control Flow and Uniform Loops

A0-SIM5 introduces wave-uniform scalar control flow.

### Scalar Registers

Scalar register space:

    S0-S31

Scalar registers contain one value shared by the entire wave.

Initial scalar arithmetic:

    SADD
    SSUB

Example:

    SADD S2, S0, S1

Semantics:

    S2 = S0 + S1

Integer arithmetic currently uses 32-bit wraparound semantics.

### Scalar Predicate Registers

A0-SIM5 introduces a scalar predicate register space:

    Q0-Q15

Each Q register contains one boolean value for the entire wave.

This is architecturally different from vector predicate registers:

    P0-P15

Vector predicates contain one predicate bit per logical thread.

Therefore:

    P registers -> lane-level conditions
    Q registers -> wave-level conditions

### SCMP_LT

Experimental opcode:

    0x63 SCMP_LT

Example:

    SCMP_LT Q0, S0, S2

Semantics:

    Q0 = (S0 < S2)

### BRA

Opcode:

    0x71 BRA

A0-SIM5 defines BRA as a uniform conditional PC-relative branch.

Syntax:

    BRA Q0, target

Semantics:

    if Q0:
        PC = NEXT_PC + SIGN_EXTEND(IMM24)
    else:
        execution continues at NEXT_PC

BRA uses the same signed IMM24 PC-relative displacement convention as JMP.

### Uniform Loop Example

Example:

loop:
    SADD S0, S0, S1
    SCMP_LT Q0, S0, S2
    BRA Q0, loop
    HALT

With:

    S0 = 0
    S1 = 1
    S2 = 5

execution produces:

    S0 = 1
    S0 = 2
    S0 = 3
    S0 = 4
    S0 = 5

The final comparison produces:

    Q0 = false

and execution reaches HALT.

### Control-Flow Separation

Current experimental architecture separates:

    JMP
        unconditional uniform wave control flow

    BRA Qn
        conditional uniform wave control flow

    SPLIT / ELSE / JOIN
        divergent lane-level control flow

This separation prevents a per-thread vector predicate from ambiguously controlling
the single wave program counter.

### Architectural Status

The Q predicate space, SCMP_LT encoding, branch encoding and structured divergence
mechanism remain experimental.

They must be evaluated through compiler experiments, RTL implementation, synthesis,
FPGA measurements and later performance/PPA studies before architectural freeze.

## A0-SIM6 Basic Memory Semantics

A0-SIM6 introduces the first complete load/store data path in the software reference model.

### Memory Model

The current simulator uses a provisional word-addressed memory model.

Each memory element contains:

    32 bits

Addresses currently identify 32-bit words rather than individual bytes.

This is intentionally temporary.

Future revisions will evaluate:

- byte addressing
- alignment rules
- address spaces
- vector address generation
- memory coalescing
- cache hierarchy
- shared/local memory
- virtual memory
- atomics
- external memory controllers
- GDDR / HBM interfaces

### Vector Load

Instruction:

    VLOAD Vdst, base

For every enabled lane:

    Vdst[lane] = MEMORY[base + lane]

The effective lane enable is:

    EXEC_MASK AND optional vector predicate

Inactive lanes preserve their previous destination-register value.

### Vector Store

Instruction:

    VSTORE Vsrc, base

For every enabled lane:

    MEMORY[base + lane] = Vsrc[lane]

The effective lane enable follows the same SIMT execution-mask rules.

### Scalar Load

Experimental opcode:

    0x52 SLOAD

Instruction:

    SLOAD Sdst, address

Semantics:

    Sdst = MEMORY[address]

### Scalar Store

Experimental opcode:

    0x53 SSTORE

Instruction:

    SSTORE Ssrc, address

Semantics:

    MEMORY[address] = Ssrc

### Memory Bounds

The simulator currently validates accesses against the configured memory size.

Vector accesses require the complete contiguous wave access range to fit within memory.

Scalar accesses require the selected address to be valid.

Invalid accesses raise an architectural simulation error.

### SIM6 Validation

Vector data-flow test:

    MEMORY[100 + lane] = lane
    V3[lane] = 10

Program:

    VLOAD  V1, 100
    VADD   V2, V1, V3
    VSTORE V2, 200
    HALT

Expected:

    MEMORY[200 + lane] = lane + 10

Predicated vector-load testing also verifies that inactive lanes preserve their
previous destination value.

Scalar validation verifies:

    memory -> SLOAD -> scalar register -> SSTORE -> memory

### Architectural Status

The current memory model proves architectural semantics only.

It does not yet model realistic GPU memory performance.

In particular, it does not yet model:

- cache hits and misses
- memory latency
- bandwidth
- bank conflicts
- transaction width
- request merging
- memory coalescing
- outstanding requests
- memory-level parallelism

These will be introduced in later simulator generations before hardware architecture
choices are frozen.

## A0-SIM7 Indexed Per-Lane Addressing

A0-SIM7 introduces indexed vector memory operations with one effective address
calculated independently for every active SIMT lane.

### Experimental Opcodes

    0x54 VLOADX
    0x55 VSTOREX

### VLOADX

Syntax:

    VLOADX Vdst, Sbase, Voffset, immediate

For every enabled lane:

    address[lane] =
        Sbase
        + Voffset[lane]
        + SIGN_EXTEND(immediate)

    Vdst[lane] = MEMORY[address[lane]]

### VSTOREX

Syntax:

    VSTOREX Vsrc, Sbase, Voffset, immediate

For every enabled lane:

    address[lane] =
        Sbase
        + Voffset[lane]
        + SIGN_EXTEND(immediate)

    MEMORY[address[lane]] = Vsrc[lane]

### Address Components

The current indexed addressing model combines:

    one wave-uniform scalar base
    one per-lane vector offset
    one signed immediate displacement

This form is intended to support future compiler lowering for patterns such as:

    buffer[index]
    vertex[index]
    pixel[y * width + x]
    indirect accesses

### Predicate and EXEC_MASK Semantics

Address generation and memory validation occur only for enabled lanes.

The effective lane enable remains:

    EXEC_MASK AND optional vector predicate

Inactive lanes:

    do not generate memory requests
    do not perform address validation
    do not fault
    preserve VLOADX destination values

This behavior is required for correct SIMT execution under divergence.

### Fault Semantics

If an enabled lane produces an address outside the current memory model,
the simulator raises an architectural simulation error.

Inactive lanes may contain arbitrary or invalid address operands because they
do not participate in the memory operation.

### Signed Immediate

VLOADX and VSTOREX use signed IMM24 displacement semantics.

Example:

    immediate = -10

is encoded as:

    0xFFFFF6

and sign-extended during address generation.

### SIM7 Validation

Indexed load/store validation uses strided vector offsets:

    S0 = 100
    S1 = 300
    V1[lane] = lane * 2

Input:

    MEMORY[100 + V1[lane]] = 1000 + lane

Program:

    VLOADX  V2, S0, V1, 0
    VADD    V4, V2, V3
    VSTOREX V4, S1, V1, 0
    HALT

with:

    V3[lane] = 5

Expected:

    MEMORY[300 + V1[lane]] = 1005 + lane

### Architectural Status

The indexed address form is experimental.

It currently defines architectural correctness only and does not yet imply any
physical address-generation-unit organization.

The next simulator generation will begin evaluating memory transaction grouping
and coalescing efficiency.

## A0-SIM8 Experimental Memory Coalescing Model

A0-SIM8 introduces the first quantitative memory-efficiency model.

This model does not yet simulate latency, caches, bandwidth limits or physical
memory-controller behavior. It measures how active per-lane word addresses group
into provisional memory transactions.

### Provisional Transaction Geometry

Current experimental values:

    memory word = 4 bytes
    transaction segment = 8 words
    transaction segment = 32 bytes

These values are not architectural commitments.

Future experiments must compare multiple transaction widths and memory-system
organizations before hardware choices are frozen.

### Transaction Grouping

Each active lane generates one word-address request.

For an address:

    word_address

the provisional transaction segment is:

    segment_id = word_address // 8

All requested words that fall within the same segment are grouped into one
memory transaction.

Inactive lanes do not contribute requests.

### Metrics

A0-SIM8 records:

    lane_requests
    unique_words
    transactions
    useful_bytes
    transferred_bytes
    coalescing_efficiency
    broadcast_factor

### Coalescing Efficiency

For the current model:

    useful_bytes =
        unique_words * 4

    transferred_bytes =
        transactions * 32

    coalescing_efficiency =
        useful_bytes / transferred_bytes

This metric represents segment utilization.

It does not by itself represent total GPU memory-system performance.

### Contiguous Access

For:

    address[lane] = lane

32 lanes request:

    0..31

These addresses occupy four 8-word transaction segments.

Result:

    lane_requests = 32
    unique_words = 32
    transactions = 4
    useful_bytes = 128
    transferred_bytes = 128
    coalescing_efficiency = 1.0

### Stride-8 Access

For:

    address[lane] = lane * 8

each active lane falls into a separate provisional transaction segment.

Result:

    lane_requests = 32
    transactions = 32
    useful_bytes = 128
    transferred_bytes = 1024
    coalescing_efficiency = 0.125

This demonstrates the cost of poorly coalesced memory access.

### Predicated Access

Only enabled lanes enter the coalescer.

For the first 16 contiguous lanes:

    lane_requests = 16
    transactions = 2
    coalescing_efficiency = 1.0

Masked lanes generate no transaction.

### Same-Address Broadcast

If all 32 lanes request the same word:

    lane_requests = 32
    unique_words = 1
    transactions = 1

The segment-utilization metric is:

    coalescing_efficiency = 0.125

but:

    broadcast_factor = 32.0

This distinction is intentional.

Low segment utilization does not imply that a broadcast is necessarily slow.
Future cache and broadcast models may exploit repeated requests to the same word.

### Memory Trace

The simulator records per-operation memory metrics.

A later performance simulator can use these traces to estimate:

- memory latency
- bandwidth consumption
- cache behavior
- transaction scheduling
- memory-level parallelism
- stalls
- latency hiding

### Architectural Status

The A0-SIM8 coalescer is a performance-modeling experiment, not a frozen hardware
design.

Transaction size, merging policy and efficiency metrics must be compared using
representative graphics, compute, ray tracing and AI workloads before committing
to a production memory architecture.

## A0-SIM9 Workgroup and Shared Memory Foundation

A0-SIM9 introduces the first explicit workgroup-level shared-memory state.

This milestone establishes shared memory between waves but does not yet model
concurrent wave scheduling or barrier synchronization.

### Workgroup State

Multiple waves may reference the same WorkgroupState.

A workgroup currently owns:

    shared memory
    shared-memory capacity

Each A0GPU wave has:

    workgroup reference
    wave_id

Example:

    workgroup = WorkgroupState()

    wave0 = A0GPU(
        workgroup=workgroup,
        wave_id=0
    )

    wave1 = A0GPU(
        workgroup=workgroup,
        wave_id=1
    )

Both waves therefore observe the same workgroup-local shared memory.

### Provisional Shared-Memory Capacity

Current experimental default:

    256 x 32-bit words

This capacity is not a production architectural commitment.

Future FPGA, synthesis, occupancy and workload experiments must determine the
appropriate physical shared-memory organization and capacity.

### Experimental Opcodes

    0x56 LDSLOAD
    0x57 LDSSTORE

LDS is currently used as the architectural name for workgroup-local shared memory.

### LDSLOAD

Syntax:

    LDSLOAD Vdst, Vaddress, immediate

For every enabled lane:

    address[lane] =
        Vaddress[lane]
        + SIGN_EXTEND(immediate)

    Vdst[lane] =
        SHARED_MEMORY[address[lane]]

### LDSSTORE

Syntax:

    LDSSTORE Vsrc, Vaddress, immediate

For every enabled lane:

    address[lane] =
        Vaddress[lane]
        + SIGN_EXTEND(immediate)

    SHARED_MEMORY[address[lane]] =
        Vsrc[lane]

### EXEC_MASK and Predicate Semantics

Only enabled lanes perform shared-memory accesses.

The effective execution condition is:

    EXEC_MASK AND optional vector predicate

Inactive lanes:

    do not read shared memory
    do not write shared memory
    do not perform address validation
    do not fault

### Cross-Wave Visibility

Waves belonging to the same WorkgroupState observe the same shared-memory contents.

A producer wave may execute:

    LDSSTORE V2, V1, 0

and another wave in the same workgroup may later execute:

    LDSLOAD V3, V1, 0

and observe the stored data.

### Current Execution Limitation

A0-SIM9 does not yet implement concurrent workgroup execution.

Cross-wave validation currently executes:

    wave0 to completion
    then wave1 to completion

Therefore the visibility demonstrated by SIM9 proves shared state, but does not
yet prove synchronization semantics.

### Barrier Requirement

Real multi-wave programs require an explicit synchronization mechanism.

A future milestone will introduce:

    cooperative wave scheduling
    barrier arrival state
    barrier waiting
    barrier release
    deadlock detection

Only after every participating wave reaches the same barrier may all waves continue.

### Bounds Semantics

Every active LDS access must satisfy:

    0 <= address < shared_memory_words

An invalid address from an active lane produces an architectural simulation error.

Masked inactive lanes do not fault.

### Architectural Status

The shared-memory instruction encoding, capacity and physical organization remain
experimental.

A0-SIM9 defines correctness and visibility semantics only.

Banking, bank conflicts, latency, bandwidth, port structure and synchronization cost
will be modeled in later generations before any hardware architecture is frozen.

## A0-SIM10 Cooperative Multi-Wave Scheduling and Barrier

A0-SIM10 introduces cooperative execution of multiple waves belonging to the
same workgroup and the first explicit synchronization primitive.

### Experimental Opcode

    0x75 BARRIER

BARRIER takes no operands and cannot be predicated.

### Wave Barrier State

Each wave maintains:

    waiting_at_barrier
    barrier_epoch

When a wave executes BARRIER:

    waiting_at_barrier = true

and the wave stops issuing further instructions until the workgroup scheduler
releases the barrier.

### Barrier Legality

The current experimental barrier requires:

    full EXEC_MASK
    no unresolved divergence

Therefore:

    all logical lanes must participate
    reconvergence_stack must be empty

A barrier encountered under partial lane participation is currently an
architectural simulation error.

This conservative rule avoids undefined workgroup synchronization semantics while
the divergence architecture remains experimental.

### Cooperative Workgroup Scheduler

WorkgroupScheduler manages multiple A0GPU waves that:

    share one WorkgroupState
    have unique wave_id values

The current scheduling policy is cooperative round-robin at instruction granularity.

Conceptually:

    Wave 0 -> one instruction
    Wave 1 -> one instruction
    Wave 0 -> one instruction
    Wave 1 -> one instruction
    ...

Waiting or halted waves do not issue instructions.

### Barrier Rendezvous

A barrier is released only when every participating scheduled wave is waiting at
the barrier.

When all waves arrive:

    barrier_epoch += 1
    barrier_releases += 1

and every wave becomes runnable again.

### Multiple Barrier Generations

The same workgroup may execute multiple synchronization points.

Example:

    BARRIER
    BARRIER
    HALT

After two successful rendezvous operations:

    barrier_epoch = 2
    barrier_releases = 2

Barrier generations prevent one synchronization event from being confused with
a later synchronization event.

### Producer / Consumer Example

Producer wave:

    LDSSTORE V2, V1, 0
    BARRIER
    HALT

Consumer wave:

    BARRIER
    LDSLOAD V3, V1, 0
    HALT

The consumer cannot execute LDSLOAD until both waves have reached the barrier.

Therefore shared-memory writes performed before the barrier are visible to the
consumer after barrier release in the current architectural model.

### Deadlock Detection

Example invalid workgroup:

Wave 0:

    BARRIER
    HALT

Wave 1:

    HALT

Wave 0 can never complete the rendezvous because Wave 1 terminated before
reaching the barrier.

The simulator detects this condition and raises a barrier deadlock error instead
of hanging indefinitely.

The scheduler also contains a maximum workgroup instruction-count guard.

### Current Scheduling Limitations

A0-SIM10 does not yet model:

    execution-unit availability
    issue width
    instruction latency
    scoreboarding
    dependency stalls
    memory stalls
    wave priority
    occupancy
    context switching
    physical SIMD width

Round-robin scheduling is currently a correctness model rather than a proposed
production scheduler.

### Architectural Status

BARRIER encoding, full-wave participation requirements, barrier scope and scheduler
policy remain experimental.

Future performance generations must evaluate synchronization cost, scheduler
fairness, latency hiding and interaction with occupancy before hardware architecture
is frozen.

## A0-SIM11 IEEE-754 FP32 Vector Arithmetic

A0-SIM11 introduces the first floating-point execution semantics in the A0
software architectural reference model.

### Register Representation

A0 does not currently use a separate floating-point register file.

Vector registers continue to contain raw 32-bit values.

The interpretation depends on the instruction.

For FP32 instructions, the 32-bit register value is interpreted as an
IEEE-754 binary32 bit pattern.

Examples:

    0x3F800000 = +1.0f
    0xBF800000 = -1.0f
    0x3FC00000 = +1.5f

This allows the same architectural vector register file to hold integer or
floating-point data.

### Canonical FP Opcodes

The existing canonical opcode assignments are preserved:

    0x20 FADD
    0x21 FSUB
    0x22 FMUL
    0x23 FFMA

A0-SIM11 also defines vector-oriented assembly aliases:

    VFADD -> FADD
    VFSUB -> FSUB
    VFMUL -> FMUL
    VFFMA -> FFMA

The aliases do not consume additional opcode space.

### VFADD

Syntax:

    VFADD Vdst, Va, Vb

Semantics for every enabled lane:

    Vdst = binary32(Va + Vb)

### VFSUB

Syntax:

    VFSUB Vdst, Va, Vb

Semantics:

    Vdst = binary32(Va - Vb)

### VFMUL

Syntax:

    VFMUL Vdst, Va, Vb

Semantics:

    Vdst = binary32(Va * Vb)

### VFFMA

Syntax:

    VFFMA Vdst, Va, Vb, Vc

Semantics:

    Vdst = binary32_fused(Va * Vb + Vc)

VFFMA performs a fused multiply-add operation with a single final binary32
rounding step.

It is intentionally not equivalent to:

    VFMUL temporary, Va, Vb
    VFADD Vdst, temporary, Vc

because the intermediate multiply in the separate sequence is rounded before
the addition.

### Fused-Rounding Validation

A0-SIM11 explicitly validates a case where fused and non-fused execution differ.

Inputs:

    a = 1 + 2^-23
    b = 1 - 2^-23
    c = -1

Exact mathematical expression:

    (1 + 2^-23) * (1 - 2^-23) - 1
    = -2^-46

Fused execution produces:

    -2^-46

while separate binary32 multiplication followed by binary32 addition produces:

    +0.0

This regression proves that VFFMA is not implemented as a simple multiply
followed by add.

### Predicated FP32 Execution

FP32 vector operations obey the same execution rules as existing vector
instructions.

Effective lane enable:

    EXEC_MASK AND optional vector predicate

Inactive lanes preserve their destination-register contents.

### IEEE-754 Special Values

Current validation includes:

    +0.0
    -0.0
    +infinity
    NaN
    normal values
    subnormal bit-pattern round trips

Examples include preservation of:

    -0.0 * +2.0 = -0.0

and propagation behavior for infinity and NaN.

### Bit-Level Conversion

The simulator includes explicit helpers that convert between:

    32-bit binary32 bit pattern
    host floating-point representation

Architectural register state remains stored as 32-bit bit patterns.

### Current FP32 Limitations

A0-SIM11 is the beginning of the FP architecture and does not yet freeze:

    rounding-mode selection
    FP exception flags
    signaling-NaN behavior
    NaN payload propagation
    denormal handling policy
    flush-to-zero behavior
    denormals-are-zero behavior
    saturation modes
    FP contraction policy
    transcendental operations

These require a stronger independent reference model and extensive edge-case
verification before architectural freeze.

### Verification Direction

Before RTL implementation is considered authoritative, FP arithmetic should be
cross-validated against an independent IEEE-754 reference implementation using:

    directed edge cases
    randomized bit patterns
    NaNs
    infinities
    signed zero
    subnormals
    overflow
    underflow
    cancellation
    fused-rounding cases

The Python model remains the current architectural golden reference but must not
be the only FP oracle used for production verification.

### Architectural Status

FP32 opcode assignments reuse the existing A0 FP opcode space.

The vector aliases, arithmetic semantics and FMA behavior are experimental until
validated against an independent IEEE-754 reference and later RTL differential
testing.

## A0-SIM12 Cycle, Latency and Throughput Model

A0-SIM12 introduces the first configurable timing model layered on top of the
functional A0 architectural simulator.

The functional simulator remains responsible for architectural correctness.

The timing scheduler adds an experimental model for:

    instruction latency
    execution-unit issue availability
    register dependencies
    completion dependencies
    memory transaction cost
    multi-wave latency hiding
    scheduler utilization
    stalls
    modeled cycle count

### Separation of Correctness and Timing

A0-SIM12 intentionally separates:

    architectural execution semantics

from:

    performance timing assumptions

The existing A0GPU execution model remains the functional golden reference.

TimingWorkgroupScheduler invokes that functional execution model while separately
tracking when architectural results become available to dependent instructions.

This prevents provisional latency assumptions from becoming part of ISA
correctness semantics.

### Timing Configuration

TimingConfig currently exposes configurable experimental parameters including:

    issue_width

    int_latency
    scalar_latency

    fp_add_latency
    fp_mul_latency
    fp_fma_latency

    global_memory_latency
    global_memory_transaction_penalty

    lds_latency
    control_latency

    int_issue_gap
    scalar_issue_gap
    fp_issue_gap
    global_memory_issue_gap
    lds_issue_gap
    control_issue_gap

These values are not production hardware commitments.

They exist so alternative microarchitectural configurations can later be
compared quantitatively.

### Dependency Scoreboard

The timing scheduler tracks ready cycles for:

    vector registers
    scalar registers
    vector predicates
    scalar predicates

A dependent instruction cannot issue until all of its required source resources
are ready.

Example:

    VFADD V3, V1, V2
    VFADD V4, V3, V2

If FP ADD latency is four cycles, the second instruction must wait until V3 is
available.

### Execution Units

Instructions are currently grouped into experimental timing classes:

    integer
    scalar
    FP
    global memory
    LDS/shared memory
    control

Each unit class has an independent issue-gap parameter.

This allows future experiments with different throughput and pipeline designs.

### Global Memory Latency

Global memory operations have a configurable base latency.

Indexed vector memory operations additionally use the A0-SIM8 coalescing result.

For VLOADX and VSTOREX:

    modeled latency =
        base global-memory latency
        + transaction penalty

where transaction penalty currently depends on the number of coalesced memory
transactions.

Therefore two functionally equivalent memory patterns may now have different
modeled execution times.

Example:

    contiguous addresses
        -> fewer transactions
        -> lower modeled latency

    highly strided addresses
        -> more transactions
        -> higher modeled latency

This is the first direct connection between A0 memory-access efficiency and
execution-time modeling.

### Multi-Wave Latency Hiding

A wave blocked by an unresolved dependency does not prevent another ready wave
from issuing.

Conceptually:

    cycle N:
        Wave 0 issues long-latency instruction

    cycle N+1:
        Wave 0 is dependency blocked
        Wave 1 issues useful work

The timing model records such cycles as latency-hidden cycles.

Latency hiding is defined independently of round-robin scan order:

    if one runnable wave is latency blocked
    while another wave successfully issues,
    latency has been hidden during that cycle

This behavior is validated by regression testing.

### Completion Points

In the current model:

    HALT
    BARRIER

act as completion points.

A wave cannot pass such a point while earlier modeled work remains outstanding.

This is a conservative first approximation and is not yet a complete memory or
pipeline ordering model.

### Performance Metrics

TimingWorkgroupScheduler currently reports:

    cycles
    instructions_issued
    IPC
    scheduler_utilization
    idle_cycles

    dependency_stall_events
    unit_stall_events
    completion_stall_events
    barrier_wait_events

    latency_hidden_cycles
    barrier_releases

These metrics are intended for comparative architectural experiments.

### Scheduler Utilization

Current scheduler utilization is:

    instructions_issued
    -------------------
    cycles * issue_width

This measures modeled issue-slot utilization rather than physical silicon
utilization.

### Current Timing Limitations

A0-SIM12 does not yet model:

    real pipeline stages
    execution ports
    cache hierarchy
    cache misses
    memory queues
    DRAM channels
    memory-level parallelism
    bank conflicts
    scoreboard hardware cost
    instruction fetch bandwidth
    decode width
    register-file ports
    operand collectors
    warp/wave dispatch hardware
    instruction replay
    branch prediction
    power
    thermal limits
    clock frequency
    physical SIMD lane count

The timing model is therefore not a prediction of final GPU clock-for-clock
performance.

It is an experimental architecture-comparison framework.

### Architectural Direction

Future generations can use this timing framework to compare candidate designs
by varying:

    number of resident waves
    issue width
    execution-unit throughput
    FP latency
    LDS latency
    memory transaction geometry
    cache design
    memory latency
    scheduler policy

The goal is to select architecture parameters from measured workload behavior
rather than freezing values based on convention or another GPU architecture.

### Architectural Status

All timing parameters and policies introduced in A0-SIM12 are provisional.

Functional architectural results remain authoritative.

Timing results are comparative experimental data until validated against RTL,
FPGA measurements and eventually physical implementation data.

## A0-SIM13 Configurable L1/L2 Cache Hierarchy

A0-SIM13 introduces the first configurable cache hierarchy in the timing model.

The cache hierarchy affects modeled execution latency but does not change
architectural memory correctness semantics.

The functional A0GPU memory remains authoritative.

### Current Hierarchy

The experimental global-memory path is:

    indexed vector memory request
        -> per-lane effective addresses
        -> A0-SIM8 coalescing
        -> cache-line grouping
        -> L1
        -> L2
        -> DRAM

The current implementation applies this timing path to:

    VLOADX
    VSTOREX

because these instructions already expose exact active per-lane addresses through
the memory trace.

### Exact Address Trace

A0-SIM13 extends the existing memory-access record with:

    word_addresses

This contains the unique active word addresses participating in the memory
instruction.

These addresses feed the timing-only cache hierarchy.

Inactive lanes continue to generate no memory request and therefore no cache
access.

### Configurable Cache Geometry

TimingConfig currently exposes:

    cache_line_words
    l1_capacity_lines
    l2_capacity_lines

The current defaults are experimental.

For example:

    cache_line_words = 16

with 32-bit words corresponds to:

    16 * 4 bytes
    = 64-byte cache lines

This is not a frozen hardware cache-line size.

### Configurable Cache Latency

The timing model also exposes:

    l1_hit_latency
    l2_hit_latency
    global_memory_latency

A cache lookup therefore produces one of three provisional timing paths:

    L1 hit
        -> l1_hit_latency

    L1 miss + L2 hit
        -> l2_hit_latency

    L1 miss + L2 miss
        -> global_memory_latency

The slowest cache-line path touched by the instruction currently determines the
base modeled latency for that memory operation.

A0-SIM8 transaction penalties may then be added on top.

### L1 Reuse

Repeated accesses to an address range already resident in L1 avoid the modeled
L2/DRAM path.

Example:

    VLOADX range A
        -> L1 miss
        -> L2 miss
        -> DRAM
        -> cache fill

    VLOADX range A again
        -> L1 hit

Regression tests verify that the repeated access produces L1 hits.

### L2 Reuse

L1 and L2 capacities are modeled independently.

An address may be evicted from L1 while remaining resident in L2.

Example:

    access A
        -> DRAM
        -> A enters L1 and L2

    access B
        -> A may be evicted from small L1

    access A again
        -> L1 miss
        -> L2 hit

This behavior is validated by regression testing.

### Cache Hits Affect Program Cycles

A0-SIM13 connects cache behavior directly to A0-SIM12 timing.

Two otherwise equivalent workloads can therefore have different modeled cycle
counts depending on locality.

Example:

    first access A
    second access A

can complete faster than:

    first access A
    second access B

when A remains resident in L1.

This is a timing-model effect, not a change to architectural program results.

### Cache Statistics

TimingWorkgroupScheduler currently reports:

    cache_line_accesses

    l1_hits
    l1_misses

    l2_hits
    l2_misses

    dram_accesses

    l1_evictions
    l2_evictions

Per-memory-operation cache activity is also available through:

    cache_access_trace

### Current Replacement Policy

The current cache model uses a fully associative LRU approximation.

This choice is intentionally simple.

It provides deterministic cache-capacity and reuse experiments without yet
committing to a physical indexing or associativity design.

### Current Fill and Store Policy

The first cache model treats indexed global memory accesses using a simplified
allocation model.

VSTOREX currently participates in the same timing cache lookup/fill framework as
VLOADX.

The following production policies are not yet frozen:

    write allocate
    no-write allocate
    write through
    write back
    dirty-line handling
    store buffering
    memory ordering

These must be modeled explicitly before the cache architecture becomes a hardware
commitment.

### Current Cache Limitations

A0-SIM13 does not yet model:

    set associativity
    cache sets
    physical tags
    dirty bits
    writeback traffic
    MSHRs
    outstanding misses
    miss merging
    memory-level parallelism
    non-blocking caches
    cache banks
    bank conflicts
    cache ports
    request queues
    prefetching
    compression
    coherence
    separate instruction cache
    texture cache
    read-only/constant cache
    TLBs
    virtual memory
    page walks

The current L1/L2 hierarchy is therefore a comparative performance model rather
than a proposed physical implementation.

### Cache Geometry Experiments

Cache-line geometry is explicitly configurable.

For 32 contiguous words:

    8-word lines
        -> 4 cache-line accesses

    16-word lines
        -> 2 cache-line accesses

Regression testing verifies this behavior.

Future architecture studies should sweep multiple:

    line sizes
    L1 capacities
    L2 capacities
    associativities
    replacement policies
    latencies

against representative graphics, compute, ray-tracing and AI workloads.

### Architectural Status

A0-SIM13 establishes the first locality-sensitive memory timing model.

Cache capacities, line size, hierarchy topology, replacement policy, write policy
and latency values remain experimental.

They must not be treated as final hardware parameters until workload simulation,
RTL experiments, FPGA measurements, synthesis and physical-design evidence support
them.

## A0-SIM14 Occupancy and Resource Pressure Model

A0-SIM14 introduces the first configurable compute-unit residency and occupancy
model.

The model connects per-kernel resource usage to:

    resident workgroups
    resident waves
    occupancy
    latency hiding
    modeled throughput

### Compute-Unit Resource Configuration

OccupancyConfig currently exposes experimental compute-unit limits:

    vector_register_words
    scalar_registers
    shared_memory_words
    max_resident_waves
    max_resident_workgroups

These values represent provisional physical-resource budgets.

They are not final hardware parameters.

### Kernel Resource Usage

KernelResourceUsage describes the provisional resource demand of one kernel:

    waves_per_workgroup
    vector_registers_per_lane
    scalar_registers_per_wave
    shared_words_per_workgroup

Vector-register pressure is converted into physical vector-register words using:

    vector words per wave =
        vector registers per lane
        * WAVE_SIZE

and:

    vector words per workgroup =
        vector words per wave
        * waves per workgroup

Scalar-register demand is similarly calculated per workgroup.

LDS/shared-memory allocation is modeled per workgroup.

### Residency Limits

A workgroup may be limited by any of:

    wave slots
    workgroup slots
    vector registers
    scalar registers
    shared memory

The number of resident workgroups is the minimum of these resource limits.

Conceptually:

    resident_workgroups =
        min(
            wave-slot limit,
            workgroup-slot limit,
            vector-register limit,
            scalar-register limit,
            shared-memory limit
        )

Resident waves are then:

    resident_waves =
        resident_workgroups
        * waves_per_workgroup

### Whole-Workgroup Residency

A0-SIM14 does not split workgroups to fill remaining wave slots.

For example:

    waves_per_workgroup = 3
    max_resident_waves = 7

allows:

    2 complete workgroups
    6 resident waves

rather than seven independently resident waves.

This is necessary for future correct workgroup-level synchronization semantics.

### Occupancy

Current occupancy is defined as:

    resident_waves
    --------------
    max_resident_waves

and is reported both as:

    occupancy
    occupancy_percent

This represents modeled wave-slot occupancy, not total silicon utilization.

### Limiting Resources

calculate_occupancy() reports the resources responsible for limiting residency.

Examples include:

    vector_registers
    scalar_registers
    shared_memory
    wave_slots
    workgroup_slots

Multiple resources may simultaneously be limiting.

### Vector Register Pressure

Higher vector-register usage can reduce the number of resident workgroups and
resident waves.

Example experimental relationship:

    lower VGPR usage
        -> more resident waves

    higher VGPR usage
        -> fewer resident waves

This behavior is validated by regression testing.

### Scalar Register Pressure

Scalar-register allocation is modeled as another independent residency limit.

Large SGPR demand per wave can therefore reduce the number of workgroups resident
on the compute unit.

### Shared-Memory Pressure

LDS/shared-memory allocation is modeled per workgroup.

Increasing:

    shared_words_per_workgroup

may reduce:

    resident_workgroups
    resident_waves
    occupancy

even when register resources remain available.

### Occupancy and Latency Hiding

A0-SIM14 connects residency directly to the A0-SIM12 timing scheduler.

For independent-wave experiments:

    calculate_occupancy()
        -> resident_waves
        -> TimingWorkgroupScheduler
        -> measured latency hiding / throughput

Therefore resource usage can now indirectly change modeled execution performance.

Conceptually:

    high register pressure
        -> fewer resident waves
        -> less latency hiding
        -> lower waves per cycle
        -> higher cycles per wave

while:

    lower register pressure
        -> more resident waves
        -> more scheduling opportunities
        -> better latency hiding

Regression tests validate this relationship.

### Resident-Wave Timing Metrics

The occupancy/timing bridge currently adds:

    resident_waves
    resident_workgroups
    occupancy
    occupancy_percent
    waves_per_cycle
    cycles_per_wave

to the timing experiment result.

### Current Workgroup-Timing Restriction

run_resident_wave_timing_experiment() currently rejects programs containing:

    BARRIER
    LDSLOAD
    LDSSTORE

This restriction is intentional.

The current helper creates an independent-wave throughput experiment and does not
yet perform full workgroup admission, workgroup-local LDS allocation and
barrier-aware residency scheduling.

Failing closed prevents an incomplete model from being mistaken for correct
workgroup execution.

### Current Occupancy Limitations

A0-SIM14 does not yet model:

    register-allocation granularity
    register-file banking
    register-file ports
    register renaming
    register spilling
    compiler allocation decisions
    multiple simultaneous kernel types
    dynamic workgroup admission
    workgroup retirement/refill
    CU partitions
    SIMD partitions
    physical execution-lane topology
    LDS bank conflicts
    LDS allocation granularity
    context switching
    preemption
    hardware scheduling queues

The current model is an architectural exploration tool.

### Compiler Direction

Future compiler work can expose real kernel resource metadata such as:

    allocated VGPRs
    allocated SGPRs
    LDS bytes
    workgroup size

That metadata can then feed the occupancy model automatically.

This creates a future optimization loop:

    shader/compiler allocation
        -> resource usage
        -> occupancy
        -> timing simulation
        -> performance feedback
        -> improved allocation decision

### Architectural Status

Resource capacities, occupancy limits and residency policies remain experimental.

A0-SIM14 establishes the framework for measuring the tradeoff between per-wave
resource allocation and total compute-unit concurrency.

Final values must be selected using workload simulation, RTL synthesis, FPGA
measurements, compiler behavior and physical-design evidence.
