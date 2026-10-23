# P130 – Exact-width raster arithmetic and end-to-end generic synthesis

Scope: narrow P38 raster edge products from padded signed-64 multiplies to
provably sufficient fixed widths. P129's raster-to-framebuffer regression stays
mandatory. The CI P130 gate also compiles the complete P102 (4×4) graphics
chain with Yosys into a generic technology-independent netlist, using genuine
Icarus and Yosys binaries.

## Integer arithmetic proof

* Vertex components are signed 16 bit: -32768..32767.
* Frame dimensions are guarded to 1..32767. `scan_x`, `scan_y` are bounded by
  0..32766; the doubled pixel-center coordinate is 1..65533.
* `dx=ex1-ex0`: -65535..65535 => signed 17 bits.
* `rx=px2-2*ex0`: -131070..131070 over pixel/vertex samples => signed 18 bits.
* Products fit in signed 35 bits; subtraction fits in signed 36 bits.
* The zero/positive edge tests and top-left convention are unchanged.
* A committed, unoptimized copy of P38 with 64-bit arithmetic is used **only
  in the testbench** as an independent cycle-by-cycle behavioral reference.

## Acceptance

* 196 deterministic corner-directed triangle cases against the original P38,
  cycle-by-cycle pixel/ready/done differential comparison in real Icarus.
* 12 strict Python tests, including 20,000 deterministic signed-range samples.
* Yosys generic synthesis of the full P102 graphics chain and nonempty,
  latch-free generic cell netlist. Both commands must exit zero.
* P126 and P129 real RTL regression remain separate required CI checks.

## Explicitly not claimed

**Not an FPGA-fit proof.** This stage does not run nextpnr for the whole P102
or constrain external pins. It does not measure FPGA Fmax, perform physical
board testing, validate VRAM/PCIe/display signals or qualify a GPU.
The HX8K P128 success applies to selected small *individual* blocks only.