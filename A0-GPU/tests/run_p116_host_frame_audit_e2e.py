#!/usr/bin/env python3
"""P116 real HDL end-to-end qualification; 0=RTL PASS, 1=FAIL, 2=NOT RUN.

Only real Icarus execution with exact expected success marker may pass.
Mocked success and local Python tests do NOT constitute RTL evidence.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GRAPH = ROOT / 'rtl' / 'graphics'
TB = ROOT / 'tests' / 'rtl' / 'a0_host_frame_audit_e2e_p116_tb.sv'
from run_p106_extended_host import FILES
MARKER = 'P116_REAL_RTL_HOST_FRAME_AUDIT_E2E_PASS'
ADDITIONAL = [
    'a0_command_progress_watchdog_p113.sv',
    'a0_scanout_liveness_guard_p114.sv',
    'a0_host_fragment_dual_bank_diagnostics_p114.sv',
    'a0_frame_event_audit_p115.sv',
    'a0_host_fragment_dual_bank_frame_audit_p115.sv',
]


def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P116_REAL_RTL_NOT_RUN: Icarus iverilog/vvp absent, exit 2', flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p116_e2e_') as tmp:
        compiled = Path(tmp) / 'e2e.vvp'
        compile_cmd = ['iverilog', '-g2012', '-Wall', '-s', TB.stem,
                       '-o', str(compiled),
                       *[str(GRAPH / x) for x in FILES + ADDITIONAL], str(TB)]
        c = subprocess.run(compile_cmd, capture_output=True, text=True, timeout=120)
        print(f'P116_COMPILE_EXIT={c.returncode}', flush=True)
        print(c.stdout + c.stderr, end='', flush=True)
        if c.returncode != 0 or not compiled.is_file():
            print('P116_REAL_RTL_FAIL_COMPILE', flush=True)
            return 1
        s = subprocess.run(['vvp', str(compiled)], capture_output=True, text=True, timeout=180)
        print(f'P116_SIM_EXIT={s.returncode}', flush=True)
        print(s.stdout + s.stderr, end='', flush=True)
        # Every stage and exact marker required; no stale marker accepted.
        if s.returncode or MARKER not in s.stdout or 'FATAL:' in (s.stdout + s.stderr):
            print('P116_REAL_RTL_FAIL_SIM', flush=True)
            return 1
        print('P116_REAL_RTL_PASS: real executable, 2 frames + host + CRC + observers', flush=True)
        return 0


if __name__ == '__main__':
    try:
        raise SystemExit(run())
    except (OSError, subprocess.TimeoutExpired) as exc:
        print('P116_REAL_RTL_FAIL', repr(exc), flush=True)
        raise SystemExit(1)
