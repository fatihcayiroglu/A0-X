#!/usr/bin/env python3
"""P113 static binding audit; not HDL compilation/simulation/timing proof."""
from pathlib import Path
from hashlib import sha256
import argparse, importlib.util, json
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('p111preflight',ROOT/'tools/a0_p111_rtl_diagnostic_preflight.py')
p111=importlib.util.module_from_spec(spec)
spec.loader.exec_module(p111)
p110=p111.p110
TOP='a0_host_fragment_dual_bank_diagnostics_p113'
MON='a0_command_progress_watchdog_p113'
PORTS={**p111.PINS,
       'cmd_opcode':'cmd_opcode','pixel_valid':'pixel_valid',
       'pixel_ready':'pixel_ready','present_pixel_count':'diagnostic_present_pixels'}

def audit(root:Path)->dict:
    base=p111.audit(root)
    rtl=root/'rtl/graphics'
    body=(rtl/(TOP+'.sv')).read_bytes()
    mon=(rtl/(MON+'.sv')).read_bytes()
    top=p110.strip_comments(body.decode())
    watch=p110.strip_comments(mon.decode())
    p110.module_ports(top,TOP)
    if p110.module_ports(watch,MON)!=set(PORTS):
        raise p110.WiringError('P113 monitor module port drift')
    p111text=p110.strip_comments((rtl/(p111.TOP+'.sv')).read_text())
    for child in p110.EDGES[p111.PARENT]:
        _,old_bindings=p111.instance_bindings(p111text,child)
        _,new_bindings=p111.instance_bindings(top,child)
        if old_bindings!=new_bindings:
            raise p110.WiringError('P113 data path changed: '+child)
    inst_name,actual=p111.instance_bindings(top,MON)
    if inst_name!='diagnostic_monitor' or actual!=PORTS:
        raise p110.WiringError('P113 monitor pin-to-wire mapping mismatch')
    if 'a0_command_completion_watchdog_p111' in top:
        raise p110.WiringError('P113 unexpectedly includes P111 monitor')
    if '.MAX_WAIT_CYCLES(MAX_COMMAND_WAIT_CYCLES)' not in top:
        raise p110.WiringError('P113 max-wait parameter not passed')
    required={
        'active_present_q && pixel_valid && pixel_ready',
        'active_present_q && pixel_valid && !pixel_ready',
        'wait_cycles_q <=',
        'MAX_WAIT_CYCLES-1'
    }
    compact=' '.join(watch.split())
    for token in required:
        if token.replace(' ','') not in compact.replace(' ',''):
            raise p110.WiringError('P113 progress rule missing: '+token)
    return {'schema':'A0-P113-STATIC-PRESENT-PROGRESS-v1','status':'PASS',
        'p111_inherited_audit':base['status'],
        'monitor_connections':len(PORTS),
        'unchanged_data_path_instances':len(p110.EDGES[p111.PARENT]),
        'source_sha256':{TOP+'.sv':sha256(body).hexdigest(),MON+'.sv':sha256(mon).hexdigest()},
        'rtl_compiled':False,'rtl_simulated':False,'physical_gpu_proven':False}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=ROOT)
    p.add_argument('--json',type=Path)
    args=p.parse_args()
    try: result=audit(args.root)
    except (p110.WiringError,OSError,UnicodeError,ValueError) as e:
        print('P113_STATIC_PREFLIGHT_FAIL',e)
        return 1
    if args.json:
        args.json.parent.mkdir(parents=True,exist_ok=True)
        args.json.write_text(json.dumps(result,sort_keys=True,indent=2)+'\n')
    print('P113_STATIC_PREFLIGHT_PASS: audited',len(PORTS),'monitor port bindings and inherited P111 datapath (NOT RTL)')
    return 0

if __name__=='__main__':raise SystemExit(main())
