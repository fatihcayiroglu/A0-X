#!/usr/bin/env python3
"""Fail-closed generic Yosys synthesis evidence for selected A0-X RTL blocks.

No FPGA device mapping, placement/routing, Fmax, bitstream or physical qualification.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TARGETS = (
    ("p68_depth_compare", "a0_p68_depth_compare", "A0-GPU/rtl/graphics/a0_p68_depth_compare.sv", None),
    ("p117_telemetry_depth4", "a0_scanout_telemetry_fifo_p117", "A0-GPU/rtl/graphics/a0_scanout_telemetry_fifo_p117.sv", 4),
    ("p118_loss_depth4", "a0_scanout_telemetry_loss_fifo_p118", "A0-GPU/rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv", 4),
    ("p118_loss_depth7", "a0_scanout_telemetry_loss_fifo_p118", "A0-GPU/rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv", 7),
)


def summarize_netlist(netlist: dict, top: str) -> dict:
    modules = netlist.get("modules")
    if not isinstance(modules, dict) or top not in modules:
        raise ValueError(f"missing synthesized top module: {top}")
    mod = modules[top]
    if mod.get("attributes", {}).get("top") not in ("00000000000000000000000000000001", "1", 1):
        raise ValueError("top attribute absent after synthesis")
    cells = mod.get("cells")
    if not isinstance(cells, dict) or not cells:
        raise ValueError("no cells in synthesized netlist")
    types = Counter(c["type"] for c in cells.values())
    latches = [k for k in types if "LATCH" in k.upper() or "DLATCH" in k.upper()]
    if latches:
        raise ValueError(f"unexpected latches: {latches}")
    unmapped = [k for k in types if k.startswith("$mem") or k.startswith("$logic")]
    if unmapped:
        raise ValueError(f"unmapped memory/RTL primitives: {unmapped}")
    ports = mod.get("ports", {})
    if not ports:
        raise ValueError("no synthesized I/O ports")
    return {"cell_count": len(cells), "cell_types": dict(sorted(types.items())),
            "port_count": len(ports), "latch_count": 0,
            "kind": "generic_technology_independent_cells"}


def command_for(top: str, source: Path, depth: int | None, netlist: Path) -> str:
    # All paths generated internally and contain no spaces or Yosys metacharacters.
    command = [f"read_verilog -sv {source.as_posix()}"]
    params = f" -chparam FIFO_DEPTH {depth}" if depth is not None else ""
    command += [f"hierarchy -check -top {top}{params}", f"synth -top {top}",
                "check -assert", f"write_json {netlist.as_posix()}"]
    return "; ".join(command)


def run(evidence_dir: Path, only: str | None = None, yosys: str = "yosys", timeout: int = 240) -> int:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    entries = [t for t in TARGETS if only is None or t[0] == only]
    if not entries:
        raise ValueError(f"invalid target: {only}")
    tool = shutil.which(yosys)
    report = {"schema": 1, "milestone": "P127", "status": "FAIL",
              "tool": "Yosys generic RTL synthesis", "tool_found": tool is not None,
              "targets_total": len(entries), "targets_passed": 0,
              "fmax_measured": False, "fpga_mapped": False, "timing_closed": False,
              "place_and_route_completed": False, "physical_gpu_qualified": False,
              "targets": []}
    try:
        if tool is None:
            for label, top, source_rel, depth in entries:
                report["targets"].append({"name": label, "status": "NOT_RUN", "reason": "yosys executable unavailable"})
            return 2
        version = subprocess.run([tool, "-V"], capture_output=True, text=True, timeout=20, check=True)
        report["yosys_version"] = version.stdout.strip()
        for label, top, source_rel, depth in entries:
            source = ROOT / source_rel
            entry = {"name": label, "top": top, "depth": depth, "source": source_rel,
                     "status": "FAIL"}
            report["targets"].append(entry)
            logpath = evidence_dir / f"{label}.log"
            if not source.is_file():
                entry["reason"] = "source file missing"
                logpath.write_text("source file missing\n")
                continue
            entry["sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            netlist_path = evidence_dir / f"{label}.netlist.json"
            script = command_for(top, source, depth, netlist_path)
            entry["yosys_script"] = script
            try:
                proc = subprocess.run([tool, "-Q", "-T", "-p", script],
                    text=True, capture_output=True, timeout=timeout, cwd=ROOT)
                logpath.write_text(proc.stdout + "\n--- STDERR ---\n" + proc.stderr)
                entry["exit_code"] = proc.returncode
                if proc.returncode:
                    entry["reason"] = "Yosys nonzero exit"
                    continue
                summary = summarize_netlist(json.loads(netlist_path.read_text()), top)
                entry.update(summary)
                entry["status"] = "PASS"
                report["targets_passed"] += 1
            except (subprocess.TimeoutExpired, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
                entry["reason"] = f"{type(exc).__name__}: {exc}"
                if not logpath.exists():
                    logpath.write_text(entry["reason"] + "\n")
            finally:
                # Netlists may be very large; retain logs and structural summaries only.
                netlist_path.unlink(missing_ok=True)
        report["status"] = "PASS" if report["targets_passed"] == len(entries) else "FAIL"
        return 0 if report["status"] == "PASS" else 1
    finally:
        report["generated_at_utc"] = datetime.now(timezone.utc).isoformat()
        (evidence_dir / "p127_synthesis.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"P127_SYNTH_{report['status']}: {report['targets_passed']}/{len(entries)} generic Yosys targets; "
              "FPGA mapped=False, timing closed=False, physical GPU qualified=False")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, default=Path("EVIDENCE/P127/synthesis"))
    parser.add_argument("--only", choices=[x[0] for x in TARGETS])
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    return run(args.evidence, args.only, args.yosys, args.timeout)


if __name__ == "__main__":
    sys.exit(main())