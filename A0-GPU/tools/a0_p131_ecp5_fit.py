#!/usr/bin/env python3
"""P131: genuine ECP5-85K feasibility gate for the *complete* P102 graphics datapath.

Synthesis and post-route utilization/Fmax are not physical-board evidence.
This deliberately rejects synthesis-only success, missing tools, unresolved
technology cells, resource overcapacity and unmet 1 MHz internal-clock timing.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TOP = "a0_triangle_scissor_depth_blend_p102"
DEVICE = "LFE5U-85F-CABGA756-speed6"
CLOCK_MHZ = 1.0
SOURCES = (
    "A0-GPU/rtl/graphics/a0_triangle_coverage_p38.sv",
    "A0-GPU/rtl/graphics/a0_p59_scissor_coverage.sv",
    "A0-GPU/rtl/graphics/a0_p68_depth_compare.sv",
    "A0-GPU/rtl/graphics/a0_p70_rgb_blend.sv",
    "A0-GPU/rtl/graphics/a0_triangle_scissor_depth_blend_p102.sv",
)


def yosys_script(netlist: Path) -> str:
    sources = " ".join(str(ROOT / p) for p in SOURCES)
    return "; ".join((
        f"read_verilog -sv {sources}",
        f"hierarchy -check -top {TOP} -chparam FRAME_WIDTH 4 -chparam FRAME_HEIGHT 4",
        f"synth_ecp5 -top {TOP} -json {netlist}",
        "check -assert",
    ))


def nextpnr_args(executable: str, netlist: Path, config: Path, report: Path) -> list[str]:
    return [executable, "--85k", "--package", "CABGA756", "--speed", "6",
            "--json", str(netlist), "--textcfg", str(config),
            "--report", str(report), "--freq", str(CLOCK_MHZ),
            "--lpf-allow-unconstrained", "--seed", "1"]


def summarize_mapped_netlist(netlist: dict) -> dict:
    if not isinstance(netlist, dict) or TOP not in netlist.get("modules", {}):
        raise ValueError("missing P102 top in ECP5 netlist")
    m = netlist["modules"][TOP]
    cells = m.get("cells")
    if not isinstance(cells, dict) or len(cells) <= 0 or not m.get("ports"):
        raise ValueError("empty mapped design or top ports")
    types = {}
    for cell in cells.values():
        typ = cell.get("type") if isinstance(cell, dict) else None
        if not isinstance(typ, str) or not typ or typ.startswith("$") or typ.startswith("a0_"):
            raise ValueError(f"unmapped or unresolved hierarchy: {typ}")
        if "LATCH" in typ.upper():
            raise ValueError("unexpected latch")
        types[typ] = types.get(typ, 0) + 1
    return {"mapped_cell_count": len(cells), "mapped_cell_types": dict(sorted(types.items()))}


def summarize_route(report: dict, min_mhz: float = CLOCK_MHZ) -> dict:
    if not isinstance(report, dict):
        raise ValueError("missing nextpnr report")
    util = report.get("utilization")
    if not isinstance(util, dict) or not util:
        raise ValueError("missing physical utilization")
    for key in ("TRELLIS_COMB", "TRELLIS_IO"):
        if key not in util:
            raise ValueError(f"missing real ECP5 resource {key}")
    resources = {}
    for key, val in util.items():
        if not isinstance(val, dict):
            raise ValueError("malformed resource")
        used, available = val.get("used"), val.get("available")
        if type(used) is not int or type(available) is not int or used < 0 or available <= 0 or used > available:
            raise ValueError(f"overcapacity or malformed resource: {key}")
        resources[key] = {"used": used, "available": available}
    if resources["TRELLIS_COMB"]["used"] == 0 or resources["TRELLIS_IO"]["used"] == 0:
        raise ValueError("FPGA design optimized away or no real I/O")
    fmax = report.get("fmax")
    if not isinstance(fmax, dict) or not fmax:
        raise ValueError("no routed clock timing witness")
    clocks = {}
    for clock, record in fmax.items():
        if not isinstance(record, dict):
            raise ValueError("malformed frequency report")
        achieved, target = record.get("achieved"), record.get("constraint")
        if (type(achieved) not in (int, float) or type(target) not in (int, float)
            or not math.isfinite(achieved) or not math.isfinite(target)
            or achieved <= 0 or achieved >= 10000 or abs(target - min_mhz) > .001):
            raise ValueError("invalid clock or changed constraint")
        if achieved < target:
            raise ValueError(f"timing failed for {clock}: {achieved:.4f} < {target:.4f} MHz")
        clocks[clock] = {"post_route_fmax_mhz": achieved, "constraint_mhz": target}
    return {"resources": resources, "internal_clocks": clocks, "internal_timing_met": True}


def run(evidence: Path, yosys: str = "yosys", nextpnr: str = "nextpnr-ecp5", timeout: int = 900) -> int:
    evidence.mkdir(parents=True, exist_ok=True)
    tools = {"yosys": shutil.which(yosys), "nextpnr_ecp5": shutil.which(nextpnr)}
    result = {
        "schema": 1, "milestone": "P131", "status": "FAIL", "target": DEVICE,
        "target_internal_mhz": CLOCK_MHZ, "frame_width": 4, "frame_height": 4,
        "tools_found": bool(all(tools.values())), "tool_paths": tools,
        "synthesis_success": False, "placed_and_routed": False,
        "io_pins_constrained": False, "external_timing_qualified": False,
        "bitstream_generated": False, "physical_device_programmed": False,
        "physical_gpu_qualified": False, "internal_timing_met": False,
    }
    netlist = evidence / "p131_mapped.json"
    cfg = evidence / "p131_routed.config"
    route_json = evidence / "p131_route_report.json"
    try:
        if not all(tools.values()):
            result["status"] = "NOT_RUN"
            result["reason"] = "real Yosys or nextpnr-ecp5 executable missing"
            return 2
        for key, command in (("yosys", "-V"), ("nextpnr_ecp5", "--version")):
            proc = subprocess.run([tools[key], command], capture_output=True, text=True, timeout=30)
            if proc.returncode:
                result["reason"] = f"{key} version probe failed"
                return 1
            result[key + "_version"] = (proc.stdout + proc.stderr).strip()[:500]
        for rel in SOURCES:
            if not (ROOT / rel).is_file():
                result["reason"] = f"source missing: {rel}"
                return 1
        result["source_sha256"] = {rel: hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() for rel in SOURCES}
        cmd = [tools["yosys"], "-Q", "-T", "-p", yosys_script(netlist)]
        try:
            synth = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, timeout=timeout)
        except subprocess.TimeoutExpired:
            result["reason"] = "Yosys synthesis timed out"
            return 1
        (evidence / "p131_yosys.log").write_text(synth.stdout + "\n--- stderr ---\n" + synth.stderr)
        result["yosys_exit_code"] = synth.returncode
        if synth.returncode or not netlist.is_file():
            result["reason"] = "actual ECP5 technology mapping failed"
            return 1
        result.update(summarize_mapped_netlist(json.loads(netlist.read_text())))
        result["synthesis_success"] = True
        cmd = nextpnr_args(tools["nextpnr_ecp5"], netlist, cfg, route_json)
        try:
            route = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, timeout=timeout)
        except subprocess.TimeoutExpired:
            result["reason"] = "nextpnr ECP5 routing timed out"
            return 1
        (evidence / "p131_nextpnr.log").write_text(route.stdout + "\n--- stderr ---\n" + route.stderr)
        result["nextpnr_exit_code"] = route.returncode
        if route.returncode or not cfg.is_file() or cfg.stat().st_size == 0:
            result["reason"] = "actual ECP5 place-and-route / timing failed"
            return 1
        if not route_json.is_file():
            result["reason"] = "post-route report absent"
            return 1
        result.update(summarize_route(json.loads(route_json.read_text())))
        result["placed_and_routed"] = True
        result["status"] = "PASS"
        return 0
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        result["reason"] = f"{type(exc).__name__}: {exc}"
        return 1
    finally:
        # Device-mapping data can be many MB. Preserve small proof reports and
        # exact logs; do not call an unprogrammed config a validated bitstream.
        netlist.unlink(missing_ok=True)
        cfg.unlink(missing_ok=True)
        result["recorded_utc"] = datetime.now(timezone.utc).isoformat()
        (evidence / "p131_ecp5_qualification.json").write_text(json.dumps(result, indent=2) + "\n")
        print(f"P131_ECP5_{result['status']}: synthesis={result['synthesis_success']}, "
              f"placed_routed={result['placed_and_routed']}, board_tested=False")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--evidence", type=Path, default=Path("EVIDENCE/P131/ecp5"))
    ap.add_argument("--timeout", type=int, default=900)
    a = ap.parse_args()
    sys.exit(run(a.evidence, timeout=a.timeout))