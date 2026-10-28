# P218 — scoped CDC ownership inventory and experimental clock contract

**Draft stacked on P217 (#94); no changes to the P216 core RTL.**

## Audited island and six declared crossings
The automated analyzer reads the actual P216 versioned display RTL, identifies sequential assignments from `always_ff` blocks and maps left-hand register ownership to its local clock. It computes all **direct cross-domain register references in those blocks**, then rejects anything not in this exact list:

1. `pixel_ready_q` (pixel → host) into `pixel_ready_meta_h_q`: first FF of a 2-stage readiness synchronizer.
2. `host_ready_q` (host → pixel) into `host_ready_meta_p_q`: first FF of the reverse 2-stage synchronizer.
3. `rgray_q` (FIFO read → write) into `w_rgray_meta_q`: two-stage Gray-pointer synchronizer.
4. `wgray_q` (FIFO write → read) into `r_wgray_meta_q`: reverse Gray-pointer synchronizer.

Two other **protocol-level crossings**, whose source is an instantiated module output or two-clock memory rather than a local register in the same module, have explicit structural invariants:

5. P210 `source_fault` (host → pixel) through `pix_fault_meta_q` and `pix_fault_q`.
6. Dual-clock FIFO payload memory (host write → pixel read), with Gray-pointer empty guard, qualified prefetch and stable output register.

The gate rejects a new or missing P216 RTL module, a new direct register crossing, missing 2-stage synchronization, changed FIFO write/read reset wiring, unguarded payload read, or lost host source reset. **Nine deliberate unsafe source mutations must all fail the audit**, not compile errors treated as success.

## Timing/report contract
`A0-GPU/constraints/p218_experimental_clock_contract.json` declares:
- ECP5-85K CABGA381, P216 exact 83-I/O top.
- Independent asynchronous `host_clk` and `pixel_clk`, *both* reported by actual nextpnr routing.
- Experimental minimum 10 MHz for **each** routed clock, in addition to existing EBR/LUT/FF assertions.
- `board_pin_map: null`, `board_timing_signoff: false`, `formal_cdc_signoff: false` by design. No invented pin numbers or board oscillator frequencies.

CI stores machine-readable `EVIDENCE/P218/cdc/inventory.json` with six crossing classifications, nine negative cases, and per-clock achieved Fmax after route. Inherited P175–P217 functional gates and real ECP5 mapping remain required; zero skipped tests and zero retries.

## What is not proved
This is a **scoped RTL/data-ownership inventory**, not a whole-chip crossing proof; the upstream P203–P210 controller internals and any future board/PCIe/DDR subsystem require separate audit. It is not STA exception signoff, multi-clock formal verification, metastability MTBF, async reset pulse-width/PVT/recovery/removal signoff, board LPF/SDC or real GPU operation. Keep PR draft until independent review and owner approval.
