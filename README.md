# A0-X GPU

Independent experimental GPU research and development project.

## Current stage: P126

The latest prepared source package covers the P126 **explicit reset-boundary telemetry receiver**, Python regressions and 18 inherited real-RTL qualification gates.

**Qualification is not yet established.** Local Python tests have passed, but real HDL simulation has not been run successfully in the available development environment. No FPGA, timing-closure, physical-board or manufactured GPU qualification is claimed.

## Source import status

**Pending:** Full P126 source tree has not yet been committed to this repository. Do not mark RTL CI successful or claim hardware qualification until source import and genuine Icarus Verilog runs complete.

The source archive and Windows GitHub publishing kit were prepared separately in the ChatGPT conversation; they are not yet present in this GitHub repository.

## Safety and scope

This repository is currently **public**. Its visibility should be changed to private before publishing source code if private development is intended.

Bridge and WolfOS are separate repositories and must not be modified as part of A0-X development.
