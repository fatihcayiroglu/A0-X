#!/usr/bin/env python3
"""Run a component with Vivado/xsim and retain auditable development evidence.

This never satisfies or changes the canonical Verilator 5.050 qualification.
An empty output directory is required, so stale simulation logs cannot pass.
All compiler diagnostics, including warnings, are retained without suppression.

Example from the repository root (use a new --out for each run):
  python tests/run_prod_seam_p37_development.py \
    --vivado-bin /opt/Xilinx/Vivado/2025.2/bin \
    --top a0_memory_channel_scheduler_tb --variant 0 \
    --source rtl/memory/a0_memory_channel_scheduler.sv \
    --source tests/rtl/a0_memory_channel_scheduler_tb.sv \
    --pass-marker "PROD_SEAM_P37_SCHEDULER_BEHAVIOR=PASS variant=0" \
    --out /tmp/p37-development-v0
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


ERROR_LINE = re.compile(r"^\s*(?:ERROR|FATAL|Fatal|CRITICAL WARNING)(?:\s*[:\[])", re.M)
NORMAL_FINISH = re.compile(r"\$finish called at time", re.I)


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes(paths: list[Path]) -> dict[str, str]:
    return {str(path): file_hash(path) for path in paths}


def resolve_tool(name: str, bindir: Path | None) -> Path:
    suffix = ".bat" if os.name == "nt" else ""
    found = bindir / (name + suffix) if bindir else shutil.which(name + suffix)
    if not found or not Path(found).is_file():
        raise FileNotFoundError(f"Cannot locate {name}; supply --vivado-bin")
    return Path(found).resolve()


def invocation(tool: Path, args: list[str]) -> tuple[list[str] | str, dict]:
    argv = [str(tool), *args]
    if os.name != "nt" or tool.suffix.lower() not in (".bat", ".cmd"):
        return argv, {"argv": argv, "shell": False}
    # Batch launch requires cmd.exe. Quote every argument, including NAME=value.
    # Refuse shell-expansion characters rather than risk cmd interpreting paths.
    for arg in argv:
        if any(char in arg for char in '\r\n"%!&|<>^'):
            raise ValueError(f"Unsafe character for Windows batch invocation: {arg!r}")
    quoted = " ".join('"' + arg + '"' for arg in argv)
    command_line = 'cmd.exe /d /s /c "' + quoted + '"'
    return command_line, {"argv": argv, "windows_command_line": command_line, "shell": False}


def run_command(name: str, tool: Path, args: list[str], out: Path,
                timeout: float, records: list[dict], environment: dict[str, str]) -> tuple[str, dict]:
    command, details = invocation(tool, args)
    stdout_path, stderr_path = out / f"{name}.stdout.log", out / f"{name}.stderr.log"
    record = {"name": name, **details, "cwd": str(out), "utc_started": utc_now(),
              "stdout_log": stdout_path.name, "stderr_log": stderr_path.name,
              "timeout_seconds": timeout, "timed_out": False, "exit_code": None}
    records.append(record)
    started = time.monotonic()
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        try:
            process = subprocess.Popen(command, cwd=out, stdout=stdout, stderr=stderr,
                                       shell=False, env=environment,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            try:
                record["exit_code"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record["timed_out"] = True
                # On Windows terminate only the process tree launched for this command.
                if os.name == "nt":
                    cleanup = subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                             shell=False, creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup_path = out / f"{name}.timeout-cleanup.log"
                    cleanup_path.write_bytes(cleanup.stdout)
                    record["timeout_cleanup_exit_code"] = cleanup.returncode
                    record["timeout_cleanup_log"] = cleanup_path.name
                else:
                    process.kill()
                try:
                    record["exit_code"] = process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    record["cleanup_error"] = "Process did not exit after timeout termination"
        except OSError as exc:
            record["launch_error"] = repr(exc)
    record["elapsed_seconds"] = round(time.monotonic() - started, 3)
    record["stdout_sha256"] = file_hash(stdout_path)
    record["stderr_sha256"] = file_hash(stderr_path)
    raw = stdout_path.read_text(encoding="utf-8", errors="replace") + "\n" + stderr_path.read_text(encoding="utf-8", errors="replace")
    record["error_lines"] = [line for line in raw.splitlines() if ERROR_LINE.search(line)]
    record["warning_lines"] = [line for line in raw.splitlines() if re.search(r"\bwarning\b", line, re.I)]
    print(json.dumps({"step": name, "exit_code": record["exit_code"],
                      "timed_out": record["timed_out"], "error_lines": record["error_lines"]}), flush=True)
    return raw, record


def command_ok(record: dict) -> bool:
    return record["exit_code"] == 0 and not record["timed_out"] and not record["error_lines"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vivado-bin", type=Path)
    parser.add_argument("--xilinx-path", type=Path,
                        help="Optional workspace-only Vivado data/compiler overlay; development use only")
    parser.add_argument("--top", required=True)
    parser.add_argument("--source", action="append", required=True, type=Path)
    parser.add_argument("--variant", type=int)
    parser.add_argument("--pass-marker", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--elaborate-only", action="store_true",
                        help="Compile and build a snapshot only; never report behavioral PASS")
    parser.add_argument("--standalone", action="store_true",
                        help="Build xelab's standalone simulator and execute it directly")
    options = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", options.top):
        parser.error("--top must be a SystemVerilog identifier")
    if options.timeout <= 0:
        parser.error("--timeout must be positive")
    if not options.pass_marker.strip() or "\n" in options.pass_marker or "\r" in options.pass_marker:
        parser.error("--pass-marker must be one nonempty line")
    files = [path.resolve(strict=True) for path in options.source]
    out = options.out.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("--out must be a new or empty directory; existing evidence is never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    result = {"schema": "a0-gpu-p37-development-v1", "status": "NOT_RUN",
              "qualification": "DEVELOPMENT_ONLY", "canonical_verilator_5_050": "NOT_RUN",
              "behavior_verification": "NOT_RUN", "elaborate_only": options.elaborate_only,
              "simulator_mode": "standalone" if options.standalone else "xsim_launcher",
              "utc_started": utc_now(), "top": options.top, "variant": options.variant,
              "required_pass_marker": options.pass_marker, "source_hashes_before": source_hashes(files),
              "runner_sha256": file_hash(Path(__file__)), "commands": []}
    sim_text = ""
    try:
        environment = os.environ.copy()
        if options.xilinx_path is not None:
            environment["XILINX_PATH"] = str(options.xilinx_path.resolve(strict=True))
        result["runtime_environment"] = {name: environment.get(name) for name in
                                         ("XILINX_PATH", "XILINX_VIVADO")}
        if environment.get("XILINX_PATH"):
            overlay = Path(environment["XILINX_PATH"])
            provenance = overlay / "runtime-provenance.json"
            result["runtime_overlay"] = {"path": str(overlay),
                                          "qualification": "DEVELOPMENT_ONLY"}
            if provenance.is_file():
                result["runtime_overlay"]["manifest_sha256"] = file_hash(provenance)
                result["runtime_overlay"]["manifest"] = json.loads(provenance.read_text(encoding="utf-8"))
            result["runtime_overlay"]["compiler_sha256"] = {
                str(path): file_hash(path) for path in
                sorted((overlay / "tps").rglob("*.exe"))
                if path.name in ("gcc.exe", "g++.exe")}
        bindir = options.vivado_bin
        if not bindir and os.environ.get("XILINX_VIVADO"):
            bindir = Path(os.environ["XILINX_VIVADO"]) / "bin"
        tool_paths = {name: resolve_tool(name, bindir) for name in ("xvlog", "xelab", "xsim")}
        if options.standalone:
            runtime_library = tool_paths["xelab"].parent.parent / "lib" / ("win64.o" if os.name == "nt" else "lnx64.o")
            variable = "PATH" if os.name == "nt" else "LD_LIBRARY_PATH"
            environment[variable] = str(runtime_library) + os.pathsep + environment.get(variable, "")
            result["runtime_library_search_prefix"] = {variable: str(runtime_library)}
        result["tool_launcher_sha256"] = {str(path): file_hash(path) for path in tool_paths.values()}
        for name, tool in tool_paths.items():
            _, record = run_command(f"00-version-{name}", tool, ["--version"], out, options.timeout, result["commands"], environment)
            if not command_ok(record):
                raise RuntimeError(f"{name} version command failed")
        snapshot = "a0_p37_development"
        # Option files preserve NAME=value through Vivado's Windows batch wrapper.
        elab_options = [options.top, "--snapshot", snapshot, "--mt", "off", "--verbose", "1"]
        if options.standalone:
            elab_options += ["--standalone"]
        if options.variant is not None:
            elab_options += ["--generic_top", '"VARIANT=' + str(options.variant) + '"']
        option_file = out / "elaborate.options"
        option_file.write_text("\n".join(elab_options) + "\n", encoding="utf-8")
        result["elaboration_options_sha256"] = file_hash(option_file)
        # The integrated bench exceeds cmd.exe's 8191-character limit. Keep the
        # complete source list in an option file, with each path separately quoted.
        compile_file = out / "compile.options"
        for path in files:
            if any(char in str(path) for char in '\r\n"'):
                raise ValueError(f"Unsafe character in compiler option-file path: {path}")
        compile_file.write_text("--sv\n" + "\n".join('"' + str(path) + '"' for path in files) + "\n",
                                encoding="utf-8")
        result["compilation_options_sha256"] = file_hash(compile_file)
        commands = [
            ("01-compile", "xvlog", ["--file", str(compile_file)]),
            ("02-elaborate", "xelab", ["--file", str(option_file)]),
        ]
        if not options.elaborate_only:
            if options.standalone:
                tool_paths["standalone"] = out / "xsim.dir" / snapshot / ("axsim.exe" if os.name == "nt" else "axsim")
                commands.append(("03-simulate", "standalone", []))
            else:
                commands.append(("03-simulate", "xsim", [snapshot, "--runall"]))
        for name, tool_name, args in commands:
            if name == "03-simulate" and options.standalone:
                result["standalone_executable_sha256"] = file_hash(tool_paths[tool_name])
            raw, record = run_command(name, tool_paths[tool_name], args, out, options.timeout, result["commands"], environment)
            if not command_ok(record):
                result["failed_step"] = name
                raise RuntimeError(f"{name} failed; inspect retained raw logs")
            if name == "03-simulate":
                sim_text = raw
        # Require both the exact requested result marker and a normal $finish.
        # xsim sometimes exits zero after an HDL $fatal; return codes alone are insufficient.
        result["pass_marker_found"] = any(line.startswith(options.pass_marker) and
                                             (len(line) == len(options.pass_marker) or line[len(options.pass_marker)].isspace())
                                             for line in sim_text.splitlines())
        result["normal_finish_found"] = bool(NORMAL_FINISH.search(sim_text))
        if not options.elaborate_only and (not result["pass_marker_found"] or not result["normal_finish_found"]):
            raise RuntimeError("Simulation did not supply both required PASS marker and normal $finish")
        result["status"] = "ELABORATION_PASS" if options.elaborate_only else "PASS"
        if not options.elaborate_only:
            result["behavior_verification"] = "PASS"
    except Exception as exc:
        result["status"] = "FAIL"
        result["error"] = repr(exc)
    finally:
        try:
            result["source_hashes_after"] = source_hashes(files)
            result["sources_unchanged"] = result["source_hashes_before"] == result["source_hashes_after"]
        except OSError as exc:
            result["sources_unchanged"] = False
            result["source_hash_error"] = repr(exc)
        if not result["sources_unchanged"]:
            result["status"] = "FAIL"
        result["runner_sha256_after"] = file_hash(Path(__file__))
        result["runner_unchanged"] = result["runner_sha256"] == result["runner_sha256_after"]
        if not result["runner_unchanged"]:
            result["status"] = "FAIL"
        if result.get("runtime_overlay"):
            try:
                before = result["runtime_overlay"]
                after = {name: file_hash(Path(name)) for name in before["compiler_sha256"]}
                provenance = Path(before["path"]) / "runtime-provenance.json"
                result["runtime_overlay_hashes_after"] = after
                result["runtime_overlay_unchanged"] = after == before["compiler_sha256"]
                if "manifest_sha256" in before:
                    result["runtime_overlay_manifest_sha256_after"] = file_hash(provenance)
                    result["runtime_overlay_unchanged"] &= file_hash(provenance) == before["manifest_sha256"]
                if not result["runtime_overlay_unchanged"]:
                    result["status"] = "FAIL"
                    result["runtime_overlay_error"] = "Compiler overlay changed during this run"
            except (OSError, KeyError) as exc:
                result["runtime_overlay_unchanged"] = False
                result["runtime_overlay_error"] = repr(exc)
                result["status"] = "FAIL"
        result["utc_finished"] = utc_now()
        (out / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"status": result["status"], "qualification": "DEVELOPMENT_ONLY",
                          "canonical_verilator_5_050": "NOT_RUN", "result": str(out / "result.json")}), flush=True)
    return 0 if result["status"] in ("PASS", "ELABORATION_PASS") else 1


if __name__ == "__main__":
    raise SystemExit(main())
