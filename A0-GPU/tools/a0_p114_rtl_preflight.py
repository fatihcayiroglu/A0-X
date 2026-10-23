#!/usr/bin/env python3
"""Fail-closed P114 named pin-to-net static audit; NOT HDL compilation."""
from pathlib import Path
from hashlib import sha256
import argparse,importlib.util,json
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('p113',ROOT/'tools/a0_p113_rtl_preflight.py')
p113=importlib.util.module_from_spec(spec);spec.loader.exec_module(p113)
p111=p113.p111;p110=p111.p110
TOP='a0_host_fragment_dual_bank_diagnostics_p114'
MON='a0_scanout_liveness_guard_p114'
BINDINGS={
'clk':'clk','rst_n':'rst_n','scan_active':'scan_active',
'pixel_valid':'pixel_valid','pixel_ready':'pixel_ready',
'pixel_x':'pixel_x','pixel_y':'pixel_y','pixel_color':'pixel_color',
'start_of_frame':'start_of_frame','end_of_line':'end_of_line',
'end_of_frame':'end_of_frame','frame_done':'frame_done',
'fault_sticky':'frame_liveness_fault','pending':'frame_liveness_pending',
'timeout_count':'frame_liveness_timeouts',
'protocol_fault_count':'frame_liveness_protocol_faults',
'completed_frames':'frame_liveness_completed',
'accepted_pixels':'frame_liveness_pixels','stalled_cycles':'frame_liveness_stalls',
'last_fault_x':'frame_liveness_fault_x','last_fault_y':'frame_liveness_fault_y'}

def audit(root:Path)->dict:
    inherited=p113.audit(root)
    g=root/'rtl/graphics';src=(g/(TOP+'.sv')).read_bytes();mon=(g/(MON+'.sv')).read_bytes()
    top=p110.strip_comments(src.decode());watch=p110.strip_comments(mon.decode())
    ports=p110.module_ports(watch,MON)
    if ports!=set(BINDINGS):raise p110.WiringError('P114 unexpected monitor pins '+repr(ports^set(BINDINGS)))
    original=p110.strip_comments((g/(p113.TOP+'.sv')).read_text())
    old_ports=p110.module_ports(original,p113.TOP)
    new_ports=p110.module_ports(top,TOP)
    if not old_ports.issubset(new_ports) or (new_ports-old_ports)!={
        'frame_liveness_fault','frame_liveness_pending','frame_liveness_timeouts',
        'frame_liveness_protocol_faults','frame_liveness_completed','frame_liveness_pixels',
        'frame_liveness_stalls','frame_liveness_fault_x','frame_liveness_fault_y'}:
        raise p110.WiringError('P114 parent port interface drift')
    for child in (*p110.EDGES[p111.PARENT],p113.MON):
        if p111.instance_bindings(original,child)!=p111.instance_bindings(top,child):
            raise p110.WiringError('P114 inherited datapath/diagnostic drift '+child)
    instance,actual=p111.instance_bindings(top,MON)
    if instance!='frame_liveness_monitor' or actual!=BINDINGS:
        raise p110.WiringError('P114 wrong frame liveness port-to-net wiring')
    monitor_inst=top[top.index(MON):top.index('frame_liveness_monitor')+len('frame_liveness_monitor')]
    if '.FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)' not in monitor_inst:
        raise p110.WiringError('P114 dimensions not forwarded to guard')
    required=['stalled_q && (!pixel_valid || held_changed)',
              'no_progress_q>=MAX_NO_PROGRESS_CYCLES-1',
              'done_delay_q>=MAX_FRAME_DONE_DELAY-1',
              'state_q<=WAIT_FRAME_DONE',
              'frame_done', 'pixel_color!=held_color_q']
    compact=''.join(watch.split())
    for token in required:
        if ''.join(token.split()) not in compact:
            raise p110.WiringError('P114 required scanout liveness rule missing: '+token)
    return {'schema':'A0-P114-SCANOUT-LIVENESS-PREFLIGHT-v1','status':'PASS',
        'inherited_p113_audit':inherited['status'],
        'inherited_submodules_unchanged':len(p110.EDGES[p111.PARENT])+1,
        'new_port_bindings':len(BINDINGS),'rtl_compiled':False,'rtl_simulated':False,
        'source_sha256':{TOP+'.sv':sha256(src).hexdigest(),MON+'.sv':sha256(mon).hexdigest()}}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=ROOT)
    p.add_argument('--json',type=Path);args=p.parse_args()
    try:result=audit(args.root)
    except (p110.WiringError,OSError,UnicodeError,ValueError) as e:
        print('P114_PREFLIGHT_FAIL',e);return 1
    if args.json:
        args.json.parent.mkdir(parents=True,exist_ok=True)
        args.json.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print('P114_PREFLIGHT_PASS: 7 unchanged submodule bindings + 21 new guard pins (STATIC ONLY)');return 0
if __name__=='__main__':raise SystemExit(main())
