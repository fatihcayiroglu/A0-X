#!/usr/bin/env python3
"""Strict A0-X P128 FPGA fabric place-and-route qualification.

Constrained chip family/package and *internal* clock target, but no physical
board pinout or timing constraints for input/output paths. This is NOT a board
build, validated bitstream, actual device measurement or GPU certification.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PART = "iCE40HX8K-CT256"
FREQ_MHZ = 5.0
# Combinational P68 is deliberately not scored on internal clock Fmax.
TARGETS = (
    ("p68_depth_compare", "a0_p68_depth_compare", "A0-GPU/rtl/graphics/a0_p68_depth_compare.sv", None, False),
    ("p117_fifo_depth4", "a0_scanout_telemetry_fifo_p117", "A0-GPU/rtl/graphics/a0_scanout_telemetry_fifo_p117.sv", 4, True),
    ("p118_loss_depth4", "a0_scanout_telemetry_loss_fifo_p118", "A0-GPU/rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv", 4, True),
    ("p118_loss_depth7", "a0_scanout_telemetry_loss_fifo_p118", "A0-GPU/rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv", 7, True),
)


def summarize_report(report: dict, expect_clock: bool, freq: float = FREQ_MHZ) -> dict:
    """Trust *post-route* nextpnr report only, never an estimated pre-route clock."""
    if not isinstance(report, dict):
        raise ValueError("nextpnr report missing or invalid JSON")
    util = report.get("utilization")
    if not isinstance(util, dict) or not util:
        raise ValueError("no device utilization evidence")
    for typ in ("ICESTORM_LC", "SB_IO"):
        if typ not in util:
            raise ValueError(f"missing device resource type {typ}")
    totals = {}
    for typ, value in util.items():
        if not isinstance(value, dict):
            raise ValueError(f"malformed resource {typ}")
        used, available = value.get("used"), value.get("available")
        if type(used) is not int or type(available) is not int or used < 0 or available <= 0 or used > available:
            raise ValueError(f"invalid/excess utilization for {typ}")
        totals[typ] = {"used": used, "available": available}
    if totals["ICESTORM_LC"]["used"] <= 0:
        raise ValueError("design optimized away or missing logic")
    timing = report.get("fmax", {})
    if timing is None:
        timing = {}
    if not isinstance(timing, dict):
        raise ValueError("invalid fmax report")
    clocks = {}
    for name, timing_result in timing.items():
        if not isinstance(timing_result, dict):
            raise ValueError("invalid clock report")
        measured, required = timing_result.get("achieved"), timing_result.get("constraint")
        if not isinstance(measured, (int, float)) or not isinstance(required, (int, float)):
            raise ValueError("missing measured frequency or constraint")
        if not 0 < measured < 10000 or abs(required - freq) > 0.01:
            raise ValueError("invalid frequency measurement or mismatched constraint")
        if measured + 1e-9 < required:
            raise ValueError(f"timing violation {name}: {measured} < {required} MHz")
        clocks[name] = {"achieved_mhz": measured, "target_mhz": required}
    if expect_clock and not clocks:
        raise ValueError("registered design has no post-route timing measurement")
    if not expect_clock and clocks:
        raise ValueError("combinational target unexpectedly has internal clock reports")
    return {"resources": totals, "clocks": clocks, "internal_clock_timing_met": bool(clocks)}


def yosys_script(top: str, src: Path, depth: int | None, netlist: Path) -> str:
    params = f" -chparam FIFO_DEPTH {depth}" if depth is not None else ""
    return "; ".join([
        f"read_verilog -sv {src.as_posix()}",
        f"hierarchy -check -top {top}{params}",
        f"synth_ice40 -top {top} -json {netlist.as_posix()}",
        "check -assert",
    ])


def nextpnr_command(pnr: str, netlist: Path, asc: Path, report: Path, freq: float = FREQ_MHZ) -> list[str]:
    return [pnr, "--hx8k", "--package", "ct256", "--json", str(netlist),
            "--asc", str(asc), "--report", str(report), "--freq", str(freq),
            "--pcf-allow-unconstrained", "--seed", "1"]


def run(evidence: Path, selected: str | None = None, yosys: str = "yosys",
        nextpnr: str = "nextpnr-ice40", timeout: int = 360) -> int:
    evidence.mkdir(parents=True, exist_ok=True)
    targets = [t for t in TARGETS if selected is None or t[0] == selected]
    if not targets:
        raise ValueError(f"unknown target: {selected}")
    found_yosys, found_pnr = shutil.which(yosys), shutil.which(nextpnr)
    result = {
        "schema": 1, "milestone": "P128", "status": "FAIL", "part": PART,
        "clock_target_mhz": FREQ_MHZ, "unconstrained_physical_pins": True,
        "io_path_timing_constrained": False, "physical_board_tested": False,
        "device_bitstream_programmed": False, "gpu_hardware_qualified": False,
        "hardware_fmax_measured": False,
        "tools_found": bool(found_yosys and found_pnr),
        "targets_total": len(targets), "targets_passed": 0, "targets": []
    }
    try:
        if not (found_yosys and found_pnr):
            result["status"] = "NOT_RUN"
            result["targets"] = [{"name": t[0], "status": "NOT_RUN", "reason": "yosys or nextpnr-ice40 missing"} for t in targets]
            return 2
        for name, program in (("yosys", found_yosys), ("nextpnr", found_pnr)):
            arg = "-V" if name == "yosys" else "--version"
            res = subprocess.run([program, arg], capture_output=True, text=True, timeout=30)
            if res.returncode:
                raise RuntimeError(f"{name} version probe failed")
            result[f"{name}_version"] = (res.stdout + res.stderr).strip()[:1000]
        for label, top, src_rel, depth, is_clocked in targets:
            entry = {"name": label, "top": top, "depth": depth, "status": "FAIL", "clocked": is_clocked, "source": src_rel}
            result["targets"].append(entry)
            src = ROOT / src_rel
            raw_netlist = evidence / f"{label}.json"
            asc = evidence / f"{label}.asc"
            report_path = evidence / f"{label}.report.json"
            try:
                if not src.is_file():
                    raise ValueError("source not found")
                entry["source_sha256"] = hashlib.sha256(src.read_bytes()).hexdigest()
                cmd = [found_yosys, "-Q", "-T", "-p", yosys_script(top, src, depth, raw_netlist)]
                synth = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
                (evidence / f"{label}.yosys.log").write_text(synth.stdout + "\nSTDERR:\n" + synth.stderr)
                entry["yosys_exit_code"] = synth.returncode
                if synth.returncode != 0 or not raw_netlist.is_file():
                    raise ValueError("Yosys mapping failed")
                n = json.loads(raw_netlist.read_text())
                if top not in n.get("modules", {}) or not n["modules"][top].get("cells"):
                    raise ValueError("mapped netlist has no top or cells")
                cells = list(n["modules"][top]["cells"].values())
                allowed = ("SB_", "ICESTORM_")
                if any(not c.get("type", "").startswith(allowed) for c in cells):
                    raise ValueError("unmapped generic cells remain")
                entry["mapped_cell_types"] = sorted(set(c["type"] for c in cells))
                command = nextpnr_command(found_pnr, raw_netlist, asc, report_path)
                place = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
                (evidence / f"{label}.nextpnr.log").write_text(place.stdout + "\nSTDERR:\n" + place.stderr)
                entry["nextpnr_exit_code"] = place.returncode
                if place.returncode != 0 or not asc.is_file() or asc.stat().st_size <= 0:
                    raise ValueError("nextpnr placement/routing failed")
                if not report_path.is_file():
                    raise ValueError("no post-route utilization/timing report")
                entry.update(summarize_report(json.loads(report_path.read_text()), is_clocked))
                entry["status"] = "PASS"
                result["targets_passed"] += 1
            except (subprocess.TimeoutExpired, OSError, ValueError, RuntimeError, KeyError, json.JSONDecodeError) as exc:
                entry["reason"] = f"{type(exc).__name__}: {exc}"
            finally:
                # Retain small machine-readable summaries + logs. ASC is an
                # *unprogrammed* implementation artifact, not a proven board image.
                raw_netlist.unlink(missing_ok=True)
                asc.unlink(missing_ok=True)
        result["status"] = "PASS" if result["targets_passed"] == len(targets) else "FAIL"
        return 0 if result["status"] == "PASS" else 1
    finally:
        result["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
        (evidence / "p128_ice40_pnr.json").write_text(json.dumps(result, indent=2) + "\n")
        print(f"P128_ICE40_{result['status']}: {result['targets_passed']}/{result['targets_total']} placed+routed; "
              "pins constrained=False, hardware tested=False")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--evidence", type=Path, default=Path("EVIDENCE/P128/ice40"))
    p.add_argument("--only", choices=[t[0] for t in TARGETS])
    p.add_argument("--yosys", default="yosys")
    p.add_argument("--nextpnr", default="nextpnr-ice40")
    p.add_argument("--timeout", type=int, default=360)
    a = p.parse_args()
    return run(a.evidence, a.only, a.yosys, a.nextpnr, a.timeout)


if __name__ == "__main__":
    sys.exit(main())