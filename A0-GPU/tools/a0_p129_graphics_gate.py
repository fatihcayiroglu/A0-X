#!/usr/bin/env python3
"""Fail-closed real Icarus integration gate for P102 4x4 raster/depth/blend.

This does NOT validate a PCIe GPU, physical VRAM, timing, pins or a monitor.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = ROOT / "A0-GPU/rtl/graphics"
TB = ROOT / "A0-GPU/tests/rtl/a0_p129_raster_depth_blend_integration_tb.sv"
SOURCES = tuple(RTL_DIR / (name + ".sv") for name in (
    "a0_triangle_coverage_p38", "a0_p59_scissor_coverage", "a0_p68_depth_compare",
    "a0_p70_rgb_blend", "a0_triangle_scissor_depth_blend_p102"
)) + (TB,)
WITNESS = "P129_REAL_RTL_GRAPHICS_INTEGRATION_PASS"
SUMMARY_PATTERN = re.compile(r"^P129_GRAPHICS_INTEGRATION_WITNESS triangles=(\d+) committed_pixels=(\d+) framebuffer=4x4$", re.M)


def parse_witness(stdout: str) -> dict:
    if not isinstance(stdout, str) or stdout.splitlines().count(WITNESS) != 1:
        raise ValueError("missing or duplicate exact P129 real RTL PASS marker")
    m = SUMMARY_PATTERN.findall(stdout)
    if len(m) != 1 or m[0] != ("3", "9"):
        raise ValueError("missing or incorrect graphics integration witness")
    if any(token in stdout for token in ("FATAL:", "ERROR:", "TIMEOUT:")):
        raise ValueError("simulator reported a fatal error")
    return {"triangles_completed": 3, "committed_pixel_events": 9, "framebuffer_pixels": 16}


def build_command(iverilog: str, output: Path) -> list[str]:
    return [iverilog, "-g2012", "-Wall", "-s", "a0_p129_raster_depth_blend_integration_tb",
            "-o", str(output), *(str(x) for x in SOURCES)]


def run(evidence: Path, iverilog: str = "iverilog", vvp: str = "vvp") -> int:
    evidence.mkdir(parents=True, exist_ok=True)
    result = {
        "milestone": "P129", "status": "FAIL", "real_simulator": False,
        "sources": {}, "real_rtl_tests_passed": 0,
        "physical_board_tested": False, "physical_gpu_qualified": False,
        "pci_express_qualified": False, "display_output_qualified": False,
        "fpga_timing_qualified": False, "device_programmed": False,
    }
    simulator = evidence / "p129_graphics.vvp"
    try:
        missing = [str(x.relative_to(ROOT)) for x in SOURCES if not x.is_file()]
        if missing:
            result["reason"] = "missing source: " + ", ".join(missing)
            return 1
        result["sources"] = {str(x.relative_to(ROOT)): hashlib.sha256(x.read_bytes()).hexdigest() for x in SOURCES}
        cc, vm = shutil.which(iverilog), shutil.which(vvp)
        if not (cc and vm):
            result["status"] = "NOT_RUN"
            result["reason"] = "real iverilog and/or vvp unavailable"
            return 2
        result["real_simulator"] = True
        for name, cmd in (("compile", build_command(cc, simulator)), ("simulate", [vm, str(simulator)])):
            try:
                p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=45)
            except (subprocess.TimeoutExpired, OSError) as exc:
                result["reason"] = f"{name} failed: {type(exc).__name__}: {exc}"
                return 1
            (evidence / f"p129_{name}.log").write_text(p.stdout + "\n--STDERR--\n" + p.stderr)
            result[f"{name}_exit_code"] = p.returncode
            if p.returncode != 0:
                result["reason"] = f"{name} returned {p.returncode}"
                return 1
            if name == "simulate":
                try:
                    result["witness"] = parse_witness(p.stdout)
                except ValueError as exc:
                    result["reason"] = str(exc)
                    return 1
        result["status"] = "PASS"
        result["real_rtl_tests_passed"] = 1
        return 0
    finally:
        simulator.unlink(missing_ok=True)
        (evidence / "p129_graphics.json").write_text(json.dumps(result, indent=2) + "\n")
        print(f"P129_GRAPHICS_{result['status']}: real RTL tests={result['real_rtl_tests_passed']}/1, physical GPU=False")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--evidence", type=Path, default=Path("EVIDENCE/P129/graphics"))
    p.add_argument("--iverilog", default="iverilog")
    p.add_argument("--vvp", default="vvp")
    a = p.parse_args()
    return run(a.evidence, a.iverilog, a.vvp)


if __name__ == "__main__":
    sys.exit(main())