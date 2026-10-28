# P220 — Dynamic full-raster reset, CDC and pixel-path mutation proof

**Draft stack:** P220 on P219 draft [#96](https://github.com/fatihcayiroglu/A0-X/pull/96). **No production RTL change.**

## Detection guarantees

The dynamic test runner first compiles and executes three positive 8-word, two-epoch P219 **complete raster** baselines (clock modes 0, 1, 2). Each must finish successfully, with an exact P219 pass marker and no HDL `FATAL`.

It then creates **six deliberately broken but compilable full P216 RTL variants**, each run against **all three** independent host/pixel clock schedules:

1. Remove the host domain's asynchronous raw-reset output mask.
2. Remove the pixel domain's asynchronous raw-reset output mask.
3. Let pixel reset release without synchronizing the stopped host's readiness; requires the specific P219 live stopped-clock assertion to fire.
4. Replace physical EBR scrub zero-data with nonzero pixels.
5. Assert video data-enable throughout blanking intervals.
6. Replace all active pixels with zero data.

Every broken variant must compile cleanly, execute Icarus `vvp` and fail with a genuine `FATAL` whose **first failure is a P216/P219 functional assertion**. Merely failing compilation, timing out, crashing for an unrelated reason, or letting a mutant pass is a **hard failure of the P220 guard**. No reruns, hidden skips, tolerances, or false-green mutants.

The runner saves the exact first failing assertion for every mutant/mode into `EVIDENCE/P220/mutation/first_failures.json` and emits 18 auditable `P220_DYNAMIC_MUTATION_REJECT` lines, plus a 3-positive-baseline summary.

## Inherited scope

The P220 workflow retains all P175–P219 positive and negative checks, P217 reset adversaries, P218 six-crossing scoped CDC audit with nine structural negatives, and the **unchanged P216 top's real ECP5-85K CABGA381 Yosys+nextpnr route** (83 IO, >=21 DP16KD, two independently reported Fmax values >=10MHz experimental floor). A failed step stops future gates, artifacts always upload. P127's path-filtered workflow is not silently treated as a pass.

This is **simulation fault sensitivity**, not formal CDC/MTBF, physical board oscillator/pin/time-signoff, metastability model, HDMI/DP, video PHY, or finished GPU/driver. Keep all PRs draft until independent review and explicit owner approval.
