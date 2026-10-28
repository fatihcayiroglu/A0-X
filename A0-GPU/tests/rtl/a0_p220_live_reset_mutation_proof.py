#!/usr/bin/env python3
"""P220 dynamic negative proof for P219 full raster, not formal CDC/MTBF.

Every mutant must compile as valid RTL and then fail an actual Icarus HDL
assertion. A syntax error, simulator crash, process timeout, or green mutant
is a failed guard, never a negative-test pass.
"""
import argparse
import json
import pathlib
import re
import subprocess
import tempfile

RTL = pathlib.Path("A0-GPU/rtl/display/a0_p216_domain_local_reset_raster.sv")
TB = pathlib.Path("A0-GPU/tests/rtl/a0_p219_clock_skew_raster_tb.sv")
SOURCES = [
    "A0-GPU/rtl/memory/a0_p203_tagged_controller_bridge.sv",
    "A0-GPU/rtl/memory/a0_p205_narrow_p203_mailbox.sv",
    "A0-GPU/rtl/memory/a0_p206_committed_bram_top.sv",
    "A0-GPU/rtl/memory/a0_p207_two_bram_banks.sv",
    "A0-GPU/rtl/memory/a0_p208_frame_publication_fence.sv",
    "A0-GPU/rtl/display/a0_p209_independent_scanout.sv",
    "A0-GPU/rtl/display/a0_p210_frame_boundary_stream.sv",
]
# Each replacement compiles but weakens a *real* reset or frame contract.
# The last field enforces a P219-specific live-clock-stop assertion when
# the host-to-pixel ready handshake is removed.
MUTANTS = [
    ("host_reset_async_event_removed",
     "always_ff @(posedge host_clk or negedge raw_rst_n)begin",
     "always_ff @(posedge host_clk)begin", None),
    ("pixel_reset_async_event_removed",
     "always_ff @(posedge pixel_clk or negedge raw_rst_n)begin",
     "always_ff @(posedge pixel_clk)begin", None),
    ("pixel_ignores_stopped_host",
     "if(pixel_ready_q[1] && host_ready_sync_p_q)pixel_up_q<=1;",
     "if(pixel_ready_q[1])pixel_up_q<=1;",
     "P219 pixel-only restart ignored stopped host clock"),
    ("pixel_ebr_scrub_writes_nonzero",
     "wire [47:0] bank_write_data=bank_scrub_write ? 48'd0 : src_data;",
     "wire [47:0] bank_write_data=bank_scrub_write ? 48'd1 : src_data;", None),
    ("video_de_bleeds_into_blanking",
     "video_de<=active && front_valid_q && !pixel_fault;",
     "video_de<=front_valid_q && !pixel_fault;", None),
    ("active_video_pixel_always_zero",
     "video_pixel<=(active && front_valid_q && !pixel_fault) ?\n                         front_read_word : 48'd0;",
     "video_pixel<=48'd0;", None),
]
FATAL = re.compile(r"^FATAL: ([^\n]+)", re.MULTILINE)


def run_case(temp: pathlib.Path, source: str, name: str, mode: int):
    rtl = temp / f"{name}_{mode}.sv"
    exe = temp / f"{name}_{mode}.vvp"
    rtl.write_text(source, encoding="utf-8")
    command = ["iverilog", "-g2012", "-Wall", "-s", "a0_p219_clock_skew_raster_tb",
               f"-Pa0_p219_clock_skew_raster_tb.WORDS=8",
               f"-Pa0_p219_clock_skew_raster_tb.MODE={mode}",
               "-o", str(exe), *SOURCES, str(rtl), str(TB)]
    compile_run = subprocess.run(command, capture_output=True, text=True,
                                 timeout=120, check=False)
    if compile_run.returncode:
        raise AssertionError(
            f"P220 {name} mode={mode} failed to compile: "
            f"{compile_run.stderr[-1200:]}")
    run = subprocess.run(["vvp", str(exe)], capture_output=True, text=True,
                         timeout=120, check=False)
    return run.returncode, run.stdout + run.stderr


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    original = RTL.read_text(encoding="utf-8")
    report = {
        "phase": "P220",
        "positive_baselines": [],
        "mutants": [],
        "compile_failures": 0,
        "escaped": 0,
        "board_signoff": False,
        "formal_cdc_signoff": False,
    }
    with tempfile.TemporaryDirectory(prefix="p220-raster-mutant-") as directory:
        temp = pathlib.Path(directory)
        # First prove the exact unmutated RTL succeeds in each clock schedule.
        for mode in (0, 1, 2):
            code, output = run_case(temp, original, "baseline", mode)
            marker = f"P219_CLOCK_SKEW_FRAME_PASS words=8 mode={mode} "
            if code or marker not in output or FATAL.search(output):
                raise AssertionError(
                    f"P220 baseline mode={mode} not a positive frame proof: "
                    f"{output[-800:]}")
            report["positive_baselines"].append({"mode": mode, "passed": True})
            print(f"P220_LIVE_RESET_BASELINE_PASS mode={mode} words=8")

        for name, old, new, required_failure in MUTANTS:
            if original.count(old) != 1:
                raise AssertionError(
                    f"P220 {name} expected exactly one RTL mutation target, "
                    f"found {original.count(old)}")
            mutant_source = original.replace(old, new)
            for mode in (0, 1, 2):
                code, output = run_case(temp, mutant_source, name, mode)
                fatal = FATAL.search(output)
                if code == 0 or fatal is None:
                    raise AssertionError(
                        f"P220 {name} mode={mode} mutant escaped an actual "
                        f"HDL FATAL: exit={code} tail={output[-1000:]}")
                first_failure = fatal.group(1).strip()
                if not ("P216" in first_failure or "P219" in first_failure):
                    raise AssertionError(
                        f"P220 {name} mode={mode} failed for unrelated "
                        f"reason: {first_failure}")
                if required_failure and required_failure not in first_failure:
                    raise AssertionError(
                        f"P220 {name} mode={mode} missed required live-stop "
                        f"assertion: {first_failure}")
                report["mutants"].append({
                    "name": name,
                    "mode": mode,
                    "compiled": True,
                    "rejected_by_hdl_fatal": True,
                    "first_failure": first_failure,
                })
                print(
                    f"P220_DYNAMIC_MUTATION_REJECT name={name} "
                    f"mode={mode} first_fatal={first_failure}")
    if len(report["positive_baselines"]) != 3 or len(report["mutants"]) != 18:
        raise AssertionError("P220 incomplete baseline/mutation matrix")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    print("P220_LIVE_RESET_MUTATION_PROOF_PASS "
          "baselines=3 dynamic_mutants=18 compile_failures=0 escaped=0 "
          "board_signoff=0 formal_cdc=0")


if __name__ == "__main__":
    main()
