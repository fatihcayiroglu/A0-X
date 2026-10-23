#!/usr/bin/env python3
"""P51 actual HDL qualification with negative RTL controls.

Exit 0: inherited P45-P50 suites ran on a REAL HDL simulator and both
        deliberately broken RTL variants failed at the expected pin assertion.
Exit 1: attempted verification failed (including mutant escape).
Exit 2: requested toolchain absent/mismatched; no RTL claim possible.

The run receipts must never be used as canonical P37 qualification evidence.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
G = ROOT / "rtl" / "graphics"
RTL = G / "a0_host_tx_fair_arbiter_p49.sv"
TB = ROOT / "tests" / "rtl" / "a0_host_tx_fair_arbiter_p50_trace_tb.sv"
ORACLE = ROOT / "tools" / "a0_fair_trace_p50.py"
INHERITED = ROOT / "tests" / "run_p50_rtl_gate.py"
TOP = "a0_host_tx_fair_arbiter_p50_trace_tb"

# Each replacement changes one and only one assignment/choice in a temporary
# copy of RTL. No inherited source is edited, and replacement count is checked.
MUTATIONS = {
    "stuck_low_valid": (
        "assign host_valid = rst_n &&",
        "assign host_valid = 1'b0 && rst_n &&",
        "host_valid mismatch",
    ),
    "inverted_tie_choice": (
        "prefer_telemetry_q ? TELEMETRY : RESULT;",
        "prefer_telemetry_q ? RESULT : TELEMETRY;",
        "host_byte mismatch",
    ),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mutated_source(original: str, mutant: str) -> str:
    before, after, _ = MUTATIONS[mutant]
    if original.count(before) != 1:
        raise ValueError(f"RTL mutation site {mutant} not unique")
    out = original.replace(before, after, 1)
    if out == original:
        raise ValueError("mutation produced no change")
    return out


def pin_mismatch_seen(log_text: str, kind: str) -> bool:
    # A compile error, crash, or arbitrary fatal is not mutation detection.
    return bool(re.search(r"P50 cycle \d+\s+" + re.escape(MUTATIONS[kind][2]), log_text))


def real_tool(name: str) -> dict | None:
    p = shutil.which(name)
    if not p:
        return None
    p = Path(p).resolve()
    return {"name": name, "path": str(p), "sha256": sha256(p)}


def run(cmd: list[str], *, cwd: Path, logfile: Path, timeout: int = 360) -> dict:
    logfile.parent.mkdir(parents=True, exist_ok=True)
    try:
        r = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True,
                           timeout=timeout, check=False)
        stdout, stderr, code = r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = (exc.stdout or b"")
        stderr = (exc.stderr or b"")
        if isinstance(stdout, bytes): stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes): stderr = stderr.decode(errors="replace")
        stderr += "\nP51 TIMEOUT\n"
        code = 124
    logfile.write_text("COMMAND: " + " ".join(map(str,cmd)) + "\n" +
                       "EXIT: " + str(code) + "\n" + stdout + "\n" + stderr,
                       encoding="utf-8")
    return {"cmd": list(map(str,cmd)), "exit_code": code,
            "log": logfile.name, "log_sha256": sha256(logfile)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", required=True, type=Path,
                    help="fresh separate directory for receipts and raw logs")
    ap.add_argument("--require-backend", choices=("auto", "iverilog", "verilator"),
                    default="auto")
    ap.add_argument("--seed", type=int, default=50050)
    ap.add_argument("--cycles", type=int, default=6000)
    args = ap.parse_args(argv)
    out = args.output.resolve()
    if out == ROOT or ROOT in out.parents:
        print("P51 output must be outside A0-GPU source tree", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)
    receipt_path = out / "receipt.json"
    receipt = {
        "kind": "P51_ACTUAL_HDL_TWO_MUTANT_QUALIFICATION",
        "status": "NOT_RUN", "canonical_p37": "NOT_CLAIMED",
        "source_sha256": sha256(RTL), "testbench_sha256": sha256(TB),
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "steps": [], "requested_backend": args.require_backend,
        "seed": args.seed, "cycles": args.cycles,
    }
    def save():
        receipt_path.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    installed = {k: real_tool(k) for k in ("iverilog", "vvp", "verilator")}
    receipt["available_tools"] = installed
    backend = "iverilog" if installed["iverilog"] and installed["vvp"] else (
        "verilator" if installed["verilator"] else None)
    if backend is None or (args.require_backend != "auto" and backend != args.require_backend):
        receipt["reason"] = "Required real simulator unavailable or inherited runner would select another backend"
        save()
        print("P51 RTL NOT RUN: " + receipt["reason"], file=sys.stderr)
        return 2
    receipt["backend"] = backend
    version_cmd = [backend, "-V"] if backend == "iverilog" else [backend, "--version"]
    vers = run(version_cmd, cwd=ROOT, logfile=out / "simulator_version.log", timeout=20)
    receipt["steps"].append({"name": "tool_version", **vers})
    if vers["exit_code"]:
        receipt.update(status="FAIL", reason="simulator version command failed");save()
        return 1
    inherited = run([sys.executable, str(INHERITED), "--seed", str(args.seed),
                     "--cycles", str(args.cycles), "--receipt", str(out / "inherited_receipt.json")],
                    cwd=ROOT, logfile=out / "inherited_P45_P50.log", timeout=900)
    receipt["steps"].append({"name": "inherited_real_RTL", **inherited})
    if inherited["exit_code"] != 0:
        receipt.update(status="FAIL",reason="P45-P50 inherited real RTL gate failed");save()
        return 1
    try:
        inherited_json = json.loads((out / "inherited_receipt.json").read_text())
        if inherited_json.get("status") != "PASS" or inherited_json.get("backend") != backend:
            raise ValueError("inherited receipt missing real PASS on selected backend")
        receipt["inherited_receipt_sha256"] = sha256(out / "inherited_receipt.json")
    except (OSError,ValueError) as exc:
        receipt.update(status="FAIL",reason=str(exc));save()
        return 1
    trace = out / "fixture.txt"
    generated = run([sys.executable, str(ORACLE), "--out", str(trace),
                     "--summary", str(out / "fixture_summary.json"),
                     "--seed", str(args.seed), "--cycles", str(args.cycles)],
                    cwd=ROOT, logfile=out / "fixture_generation.log", timeout=120)
    receipt["steps"].append({"name": "fixture_generation", **generated})
    if generated["exit_code"]:
        receipt.update(status="FAIL",reason="fixture generation failed");save()
        return 1
    receipt["fixture_sha256"] = sha256(trace)
    original = RTL.read_text(encoding="utf-8")
    for name in MUTATIONS:
        mutant = out / ("mutant_" + name + ".sv")
        mutant.write_text(mutated_source(original,name),encoding="utf-8")
        receipt["steps"].append({"name": "mutant_source_" + name, "sha256": sha256(mutant)})
        if backend == "iverilog":
            executable = out / ("mutant_" + name + ".vvp")
            build_cmd = ["iverilog", "-g2012", "-s", TOP, "-o",str(executable),str(mutant),str(TB)]
            run_cmd = ["vvp",str(executable),"+TRACE="+str(trace)]
        else:
            obj = out / ("obj_" + name)
            build_cmd = ["verilator", "--binary", "--timing", "--assert",
                         "--top-module",TOP,"--Mdir",str(obj),str(mutant),str(TB)]
            run_cmd = [str(obj / ("V"+TOP)),"+TRACE="+str(trace)]
        built = run(build_cmd, cwd=ROOT, logfile=out/(name+"_build.log"),timeout=480)
        receipt["steps"].append({"name":name+"_compile", **built})
        if built["exit_code"]:
            receipt.update(status="FAIL",reason="negative control compile failed: " + name);save()
            return 1
        executed = run(run_cmd,cwd=ROOT,logfile=out/(name+"_execute.log"),timeout=120)
        logfile = (out / executed["log"]).read_text()
        detected = executed["exit_code"] != 0 and pin_mismatch_seen(logfile,name)
        receipt["steps"].append({"name":name+"_negative_runtime", **executed,
                                  "expected_pin_mismatch_detected": detected})
        if not detected:
            receipt.update(status="FAIL",reason="negative RTL mutant escaped or failed without pin mismatch: "+name)
            save()
            return 1
    if sha256(RTL) != receipt["source_sha256"] or sha256(TB) != receipt["testbench_sha256"]:
        receipt.update(status="FAIL",reason="original source/testbench mutated during validation");save()
        return 1
    receipt.update(status="PASS",reason="Real inherited RTL and both negative pin mutants verified")
    save()
    print("P51 REAL RTL GATE PASS (inherited P45-P50 plus two semantic mutants)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
