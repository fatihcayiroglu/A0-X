#!/usr/bin/env python3
"""P115 fail-closed real HDL gate. 0=real PASS,1=FAIL,2=NOT RUN."""
from pathlib import Path
import shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
GRAPH=ROOT/'rtl/graphics'
TB=ROOT/'tests/rtl/a0_frame_event_audit_p115_tb.sv'
MON=GRAPH/'a0_frame_event_audit_p115.sv'
TOP=GRAPH/'a0_host_fragment_dual_bank_frame_audit_p115.sv'
sys.path.insert(0,str(ROOT/'tests'))
from run_p106_extended_host import FILES
MARKER='P115_REAL_RTL_FRAME_EVENT_AUDIT_PASS'

def run():
    if not (shutil.which('iverilog') and shutil.which('vvp')):
        print('P115_REAL_RTL_NOT_RUN: iverilog/vvp unavailable; exit 2',flush=True)
        return 2
    with tempfile.TemporaryDirectory(prefix='a0_p115_') as tmp:
        tmp=Path(tmp)
        jobs=[
            (['iverilog','-g2012','-Wall','-s',TB.stem,'-o',str(tmp/'audit.vvp'),str(MON),str(TB)],'AUDIT_COMPILE'),
            (['vvp',str(tmp/'audit.vvp')],'AUDIT_SIM'),
            (['iverilog','-g2012','-Wall','-s',TOP.stem,'-o',str(tmp/'top.vvp'),
              *[str(GRAPH/f) for f in FILES],
              str(GRAPH/'a0_command_progress_watchdog_p113.sv'),
              str(GRAPH/'a0_scanout_liveness_guard_p114.sv'),
              str(GRAPH/'a0_host_fragment_dual_bank_diagnostics_p114.sv'),
              str(MON),str(TOP)],'FULL_TOP_ELABORATION')]
        for cmd,label in jobs:
            p=subprocess.run(cmd,capture_output=True,text=True,timeout=120)
            print(label,'EXIT',p.returncode,flush=True)
            print(p.stdout+p.stderr,end='',flush=True)
            if p.returncode:
                print('P115_REAL_RTL_FAIL_'+label)
                return 1
            if label=='AUDIT_SIM' and MARKER not in p.stdout:
                print('P115_REAL_RTL_FAIL_MISSING_MARKER')
                return 1
    print('P115_REAL_RTL_PASS: monitor simulated AND all inherited modules elaborated')
    return 0

if __name__=='__main__':
    try:raise SystemExit(run())
    except (OSError,subprocess.TimeoutExpired) as exc:
        print('P115_REAL_RTL_FAIL',exc)
        raise SystemExit(1)
