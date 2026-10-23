# A0-X GPU — experimental GPU development

This public repository contains research-stage GPU source work. It is **not** a manufactured, FPGA-qualified, timing-closed, or hardware-validated GPU.

## P126 staged import status

The P126 reset-boundary host receiver is being transferred from the verified source archive. The complete P126 source tree is **not yet present**, including supporting P119 code, RTL sources, test vectors and P126 qualification tooling.

- `A0-GPU/sim/a0_p126_reset_boundary_receiver.py`: host-side reset epoch isolation, depends on P119 reconciler (not yet imported).
- `ci/staged/a0-p126-reset-boundary-18-real-rtl.yml`: proposed real Icarus Verilog qualification workflow, **intentionally inactive until dependencies arrive**.
- After full source import the workflow will be moved to `.github/workflows/` and real HDL results will be checked.

**Current evidence:** local Python-only tests passed in the previously prepared package; GitHub has not run the 18 actual RTL tests. No fake PASS is permitted. No RTL, FPGA, device authentication or physical GPU certification is asserted.

The project is intended to remain **public** as the owner requested. Bridge and WolfOS are separate and must not be modified by A0-X tasks.
