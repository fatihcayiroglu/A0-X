#!/usr/bin/env python3
"""P222 first-FATAL dynamic mutation proof of P221's real FIFO saturation.

A mutation counts only if valid RTL compiles, executes, and fails on an actual
P212/P221 HDL functional assertion. Compilation failure, timeout, unrelated
crash or escaped green mutant is a failed proof. Not formal CDC/MTBF.
"""
import argparse
import json
import pathlib
import re
import subprocess
import tempfile

RTL = pathlib.Path("A0-GPU/rtl/display/a0_p216_domain_local_reset_raster.sv")
TB = pathlib.Path("A0-GPU/tests/rtl/a0_p221_saturated_split_queue_tb.sv")
SOURCES = [
    "A0-GPU/rtl/memory/a0_p203_tagged_controller_bridge.sv",
    "A0-GPU/rtl/memory/a0_p205_narrow_p203_mailbox.sv",
    "A0-GPU/rtl/memory/a0_p206_committed_bram_top.sv",
    "A0-GPU/rtl/memory/a0_p207_two_bram_banks.sv",
    "A0-GPU/rtl/memory/a0_p208_frame_publication_fence.sv",
    "A0-GPU/rtl/display/a0_p209_independent_scanout.sv",
    "A0-GPU/rtl/display/a0_p210_frame_boundary_stream.sv",
]
MUTANTS = [
    ("disable_fifo_full_detection",
     "wire full=(wgray_q==",
     "wire full=1'b0 && (wgray_q=="),
    ("bypass_fifo_full_backpressure",
     "assign wr_ready=wr_rst_n && w_release_q && !full;",
     "assign wr_ready=wr_rst_n && w_release_q;"),
    ("read_pointer_skips_one_packet",
     "rbin_q<=rbin_q+1'b1;",
     "rbin_q<=rbin_q+2'd2;"),
    ("read_wrong_ebr_payload_slot",
     "rd_data_q<=mem[rbin_q[ADDR_BITS-1:0]];",
     "rd_data_q<=mem[rbin_q[ADDR_BITS-1:0]+1'b1];"),
    ("swap_frame_start_end",
     "assign {frame_end,frame_start,pixel_epoch,pixel_index,pixel_data}=",
     "assign {frame_start,frame_end,pixel_epoch,pixel_index,pixel_data}="),
    ("prefetch_invalid_empty_fifo",
     "wire prefetch=r_release_q && !rd_valid_q && !empty;",
     "wire prefetch=r_release_q && !rd_valid_q;"),
]
FATAL = re.compile(r"^FATAL: ([^\n]+)", re.MULTILINE)


def execute(temp: pathlib.Path, rtl: str, name: str, size: int, mode: int):
    source = temp / f"{name}_{size}_{mode}.sv"
    executable = temp / f"{name}_{size}_{mode}.vvp"
    source.write_text(rtl, encoding="utf-8")
    command = [
        "iverilog", "-g2012", "-Wall", "-s", "a0_p221_saturated_split_queue_tb",
        f"-Pa0_p221_saturated_split_queue_tb.WORDS={size}",
        f"-Pa0_p221_saturated_split_queue_tb.MODE={mode}",
        "-o", str(executable), *SOURCES, str(source), str(TB),
    ]
    compiled = subprocess.run(command, capture_output=True, text=True,
                              timeout=120, check=False)
    if compiled.returncode:
        raise AssertionError(
            f"P222 {name} words={size} mode={mode} compilation FAILED: "
            f"{compiled.stderr[-1200:]}")
    simulation = subprocess.run(["vvp", str(executable)],
                                capture_output=True, text=True, timeout=120,
                                check=False)
    return simulation.returncode, simulation.stdout + simulation.stderr


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    original = RTL.read_text(encoding="utf-8")
    report = {
        "phase": "P222",
        "baselines": [],
        "rejected_mutants": [],
        "compilation_failures": 0,
        "escaped": 0,
        "formal_cdc_signoff": False,
        "board_timing_signoff": False,
    }
    variants = {}
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            raise AssertionError(
                f"P222 {name} needs exactly one mutation target, "
                f"found {original.count(old)}")
        variants[name] = original.replace(old, new)

    with tempfile.TemporaryDirectory(prefix="p222-cdc-full-mutants-") as dirname:
        temp = pathlib.Path(dirname)
        for size in (8, 1024):
            for mode in (0, 1):
                code, output = execute(temp, original, "baseline", size, mode)
                marker = f"P221_SATURATED_CDC_PASS words={size} mode={mode} "
                if code or marker not in output or FATAL.search(output):
                    raise AssertionError(
                        f"P222 invalid baseline size={size} mode={mode} "
                        f"exit={code} tail={output[-900:]}")
                report["baselines"].append({"words": size, "mode": mode,
                                            "actual_rtl": True, "passed": True})
                print(f"P222_POSITIVE_BASELINE_PASS words={size} mode={mode}")
        for name, broken in variants.items():
            for size in (8, 1024):
                for mode in (0, 1):
                    code, output = execute(temp, broken, name, size, mode)
                    failure = FATAL.search(output)
                    if code == 0 or failure is None:
                        raise AssertionError(
                            f"P222 escaped mutant name={name} words={size} "
                            f"mode={mode} exit={code} tail={output[-1200:]}")
                    first_failure = failure.group(1).strip()
                    if not ("P212" in first_failure or "P221" in first_failure):
                        raise AssertionError(
                            f"P222 unrelated failure name={name} "
                            f"words={size} mode={mode} first={first_failure}")
                    report["rejected_mutants"].append({
                        "name": name,
                        "words": size,
                        "mode": mode,
                        "compiled": True,
                        "rejected_by_hdl_fatal": True,
                        "first_failure": first_failure,
                    })
                    print(f"P222_DYNAMIC_MUTATION_REJECT name={name} "
                          f"words={size} mode={mode} "
                          f"first_fatal={first_failure}")
    if len(report["baselines"]) != 4 or len(report["rejected_mutants"]) != 24:
        raise AssertionError("P222 incomplete 4 positive / 24 negative matrix")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
    print("P222_FIFO_MUTATION_PROOF_PASS "
          "baselines=4 dynamic_mutants=24 compilation_failures=0 escaped=0 "
          "board_signoff=0 formal_cdc=0")


if __name__ == "__main__":
    main()
