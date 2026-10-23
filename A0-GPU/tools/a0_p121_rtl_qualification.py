#!/usr/bin/env python3
"""P121 single fail-closed gate for all inherited Icarus RTL benches.

EXIT 0: fourteen real HDL sub-gates ran and were verified by their markers.
EXIT 1: missing/corrupt files, failed sub-gates, invalid outputs, or timeout.
EXIT 2: Icarus/vvp not installed; NO RTL tests qualified.

Python unit tests may mock run_all's executor to test rejection logic. Such
mock runs are NEVER real RTL qualification and MUST NOT be used as evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

PROJECT = Path(__file__).resolve().parents[1]
# The marker must have come from a successful underlying compile + vvp runner.
# Each inherited runner is already responsible for checking that requirement.
GATES = (
    ("P103", "run_p103_command_pixel.py", "P103_REAL_RTL_PASS"),
    ("P104", "run_p104_dual_bank.py", "P104_REAL_RTL_PASS"),
    ("P105", "run_p105_host_dual_bank.py", "P105_REAL_RTL_PASS"),
    ("P106", "run_p106_extended_host.py", "P106_REAL_RTL_PASS"),
    ("P111", "run_p111_diagnostics_rtl.py", "P111_DIAGNOSTIC_RTL_PASS"),
    ("P112", "run_p112_watchdog_trace.py", "P112_WATCHDOG_RTL_CYCLE_TRACE_PASS"),
    ("P113", "run_p113_progress_watchdog.py", "P113_REAL_RTL_PROGRESS_WATCHDOG_PASS"),
    ("P114", "run_p114_scanout_liveness.py", "P114_REAL_RTL_SCANOUT_LIVENESS_PASS"),
    ("P115", "run_p115_frame_event_audit.py", "P115_REAL_RTL_FRAME_EVENT_AUDIT_PASS"),
    ("P116", "run_p116_host_frame_audit_e2e.py", "P116_REAL_RTL_HOST_FRAME_AUDIT_E2E_PASS"),
    ("P117_FIFO", "run_p117_telemetry_fifo.py", "P117_REAL_RTL_TELEMETRY_FIFO_PASS"),
    ("P117_E2E", "run_p117_host_fifo_e2e.py", "P117_REAL_RTL_HOST_FIFO_E2E_PASS"),
    ("P118_FIFO", "run_p118_loss_fifo.py", "P118_REAL_RTL_LOSS_NOTICE_PASS"),
    ("P118_E2E", "run_p118_host_loss_e2e.py", "P118_REAL_RTL_HOST_LOSS_E2E_PASS"),
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_hashes(project: Path) -> dict[str, str]:
    """Hash RTL modules, RTL benches, gates, traces, and the P121 runner."""
    files = [*project.glob('rtl/graphics/*.sv'), *project.glob('tests/rtl/*.sv'),
             *project.glob('tests/vectors/*.hex'), project/'tools/a0_p121_rtl_qualification.py']
    files.extend(project/'tests'/script for _, script, _ in GATES)
    unique = {f.relative_to(project).as_posix(): f for f in files}
    if not files or any(not f.is_file() for f in unique.values()):
        raise FileNotFoundError('missing HDL source/bench/runner')
    return {key: sha256(unique[key].read_bytes()) for key in sorted(unique)}


def count_marker(output: str, marker: str) -> int:
    """Count a TB pass line, not text embedded in a longer status token."""
    return sum(line.strip() == marker or line.strip().startswith(marker + ' ')
               for line in output.splitlines())


def assess(exit_code: int, output: str, marker: str) -> tuple[str, str]:
    if exit_code == 2:
        return 'NOT_RUN', 'runner exit 2'
    if exit_code != 0:
        return 'FAIL', 'runner nonzero'
    if 'NOT_RUN' in output or 'FATAL:' in output or 'Traceback (most recent call last)' in output:
        return 'FAIL', 'forbidden diagnostic in output'
    if count_marker(output, marker) != 1:
        return 'FAIL', 'expected exact TB marker absent or duplicated'
    return 'PASS', 'runner exit 0 + exact TB witness'


def atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                     prefix='.p121-', suffix='.tmp', delete=False) as fd:
        json.dump(payload, fd, indent=2, sort_keys=True)
        fd.write('\n')
        tmp = Path(fd.name)
    os.replace(tmp, path)


def execute_subgate(python: str, script: Path, project: Path, timeout: int):
    p = subprocess.run([python, '-B', str(script)], cwd=project,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors='replace', timeout=timeout,
                       env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
    return p.returncode, p.stdout


def run_all(project: Path, evidence: Path, *, locate=shutil.which,
            execute=execute_subgate, timeout: int=240) -> tuple[int, dict]:
    project = Path(project).resolve()
    evidence = Path(evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    injected_executor = (locate is not shutil.which or execute is not execute_subgate)
    report = {
        'execution_mode': ('MOCKED_UNIT_TEST' if injected_executor else 'REAL_SUBPROCESS'),
        'schema': 'A0-P121-RTL-QUALIFICATION-1',
        'date_utc': datetime.now(timezone.utc).isoformat(),
        'qualification_scope': 'Icarus compile and vvp simulation of 14 inherited HDL gates',
        'physical_prototype': False,
        'gates_expected': len(GATES),
        'gates': [],
        'toolchain': {'iverilog': locate('iverilog'), 'vvp': locate('vvp')},
        'sources': {},
        'status': 'NOT_RUN',
        'qualified': False,
    }
    try:
        report['sources'] = source_hashes(project)
    except (OSError, ValueError) as exc:
        report['status'] = 'FAIL'
        report['reason'] = 'missing required RTL files or runners: ' + str(exc)
        atomic_json(evidence/'qualification.json', report)
        return 1, report

    if not (report['toolchain']['iverilog'] and report['toolchain']['vvp']):
        report['reason'] = 'iverilog/vvp absent; no RTL test executed'
        report['gates'] = [{'name': name, 'status': 'NOT_RUN', 'script': script}
                           for name, script, _ in GATES]
        atomic_json(evidence/'qualification.json', report)
        return 2, report

    for name, script, marker in GATES:
        runner = project/'tests'/script
        try:
            code, output = execute(sys.executable, runner, project, timeout)
            status, reason = assess(code, output, marker)
        except (subprocess.TimeoutExpired, TimeoutError) as exc:
            code, output, status, reason = None, str(exc), 'FAIL', 'timeout'
        except Exception as exc:
            code, output, status, reason = None, repr(exc), 'FAIL', 'execution failure'
        log_name = name.lower() + '.log'
        data = output.encode('utf-8', errors='replace')
        (evidence/log_name).write_bytes(data)
        if injected_executor and status == 'PASS':
            status, reason = 'MOCK_PASS', 'test-injected executor: NOT real Icarus evidence'
        report['gates'].append({
            'name': name, 'script': script, 'marker': marker, 'status': status,
            'reason': reason, 'exit_code': code, 'log': log_name,
            'log_sha256': sha256(data), 'log_bytes': len(data),
        })
    all_pass = len(report['gates']) == len(GATES) and all(
        item['status'] == 'PASS' for item in report['gates'])
    report['qualified'] = all_pass
    report['status'] = 'PASS' if all_pass else ('MOCK_ONLY' if injected_executor and all(
        item['status'] == 'MOCK_PASS' for item in report['gates']) else 'FAIL')
    report['reason'] = ('all 14 real HDL gates passed' if all_pass else
                        'all injected markers passed but NO real HDL ran' if report['status']=='MOCK_ONLY' else
                        'at least one gate failed or did not run')
    atomic_json(evidence/'qualification.json', report)
    return (0 if all_pass else 1), report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path,
                        default=PROJECT.parent/'EVIDENCE/P121/rtl_qualification')
    args = parser.parse_args(argv)
    code, data = run_all(PROJECT, args.evidence)
    print(f"P121_REAL_RTL_QUALIFICATION_{data['status']}: "
          f"{sum(r['status']=='PASS' for r in data['gates'])}/{len(GATES)} gates; "
          f"evidence={args.evidence}", flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
