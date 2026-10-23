# P51 — Real simulator qualification and semantic mutation controls

## Motivation

Passing software reference tests proves software logic, not RTL correctness.
P45–P50 produced candidate RTL and simulation testbenches, but their primary
verification gate was not executed with a genuine HDL simulator in the working
container. P51 does not claim to fix the missing runs locally; it packages an
honest real-tool gate which can execute on a supported development machine.

## Acceptance contract

1. The user explicitly selects a real HDL simulator, or allows auto-selection.
2. The inherited P50 test runner executes actual P45–P49 HDL benches and P50
   cycle trace. Any nonzero exit is failure; its JSON receipt must say PASS
   with precisely the selected backend.
3. A temporary RTL copy forces `host_valid` low. Compilation must succeed and
   execution must fail at the expected P50 `host_valid mismatch` assertion.
4. A second temporary RTL copy inverts the initial tie-breaking preference.
   Compilation must succeed and execution must fail at the expected P50
   `host_byte mismatch` assertion.
5. Source and testbench SHA-256 values must remain unchanged across the run.
6. All commands, exit codes and unfiltered stdout/stderr are persisted under
   the designated output directory.

A generic segmentation fault, missing trace, simulator build failure, timeout,
or unrelated HDL assertion is not sufficient to mark a mutant as caught. A
passing mutated design is a FAIL, not a green qualification.

## Expected simulator behavior

The P49 fair arbiter alternates complete 16-byte A0GR result frames and
32-byte A0GF telemetry frames when both are continuously offered. The P50
independent reference stimulus exercises simultaneous valid sources, large
backpressure windows, reset interruption, complete packet arbitration and
non-vacuous accepted bytes. Mutation tests target two observable external pins:
valid and selected data. Neither mutation changes the frozen production RTL.

## Scope restrictions

This is a **development RTL correctness** gate; it is not timing closure,
formal verification, physical FPGA validation, or canonical P37 closure. The
Icarus / Verilator versions delivered by the OS package manager are recorded
at execution time and must not be misrepresented as canonical Verilator 5.050.
