#!/usr/bin/env python3
"""P111 bounded static port-wire inspection, NOT HDL elaboration or simulation."""
from __future__ import annotations
import argparse
import importlib.util
from pathlib import Path
import json
import re
from hashlib import sha256

ROOT=Path(__file__).resolve().parents[1]
TOOL=ROOT/'tools'/'a0_p110_rtl_wiring_preflight.py'
spec=importlib.util.spec_from_file_location('a0_p110_source_checker',TOOL)
assert spec and spec.loader
p110=importlib.util.module_from_spec(spec)
spec.loader.exec_module(p110)

TOP='a0_host_fragment_dual_bank_diagnostics_p111'
WATCH='a0_command_completion_watchdog_p111'
PARENT='a0_host_fragment_dual_bank_bridge_p106'
PINS={
    'cmd_valid':'cmd_valid','cmd_ready':'cmd_ready','cmd_tag':'cmd_tag',
    'completion_valid':'completion_valid','completion_ready':'completion_ready',
    'completion_tag':'completion_tag','completion_error':'completion_error',
    'fault_sticky':'diagnostic_fault','pending':'diagnostic_pending',
    'active_tag':'diagnostic_active_tag','last_fault_tag':'diagnostic_last_fault_tag',
    'timeout_count':'diagnostic_timeouts',
    'tag_mismatch_count':'diagnostic_tag_mismatches',
    'protocol_fault_count':'diagnostic_protocol_faults',
    'completed_count':'diagnostic_completed',
    'clk':'clk','rst_n':'rst_n',
}


def instance_bindings(text: str, child: str) -> tuple[str, dict[str,str]]:
    """Parse the single explicit instance with bounded balanced-parentheses rules."""
    locations=[]
    for m in re.finditer(r'\b'+re.escape(child)+r'\b', text):
        i=p110.skip_space(text,m.end())
        if i<len(text) and text[i]=='#':
            i=p110.skip_space(text,i+1)
            i=p110.skip_space(text,p110.bracket(text,i))
        ident=re.match(r'[A-Za-z_]\w*',text[i:])
        if not ident:continue
        label=ident.group()
        i=p110.skip_space(text,i+len(label))
        if i>=len(text) or text[i]!='(':continue
        end=p110.bracket(text,i)
        if text[p110.skip_space(text,end)]!=';':continue
        pairs={}
        for entry in p110.split_top(text[i+1:end-1]):
            match=re.fullmatch(r'\.([A-Za-z_]\w*)\s*\((.*)\)',entry,re.S)
            if not match:raise p110.WiringError(f'{child}: missing/positional/empty connection')
            pin,wire=match.group(1),match.group(2).strip()
            if pin in pairs or not wire:
                raise p110.WiringError(f'{child}: duplicate/empty wiring')
            pairs[pin]=wire
        locations.append((label,pairs))
    if len(locations)!=1:
        raise p110.WiringError(f'{child}: expected one concrete instance, got {len(locations)}')
    return locations[0]


def audit(root: Path) -> dict:
    previous=p110.audit(root)
    rtl=root/'rtl'/'graphics'
    src=(rtl/(TOP+'.sv')).read_bytes()
    mon=(rtl/(WATCH+'.sv')).read_bytes()
    toptext=p110.strip_comments(src.decode())
    montext=p110.strip_comments(mon.decode())
    p110.module_ports(toptext,TOP)
    mon_ports=p110.module_ports(montext,WATCH)
    if mon_ports!=set(PINS):
        raise p110.WiringError(f'P111 diagnostic port contract mismatch {mon_ports ^ set(PINS)}')
    inherited_top=p110.strip_comments((rtl/(PARENT+'.sv')).read_text())
    for parent,expected in p110.EDGES[PARENT].items():
        inst=p110.find_instances(toptext,parent,TOP)
        if len(inst)!=expected:
            raise p110.WiringError(f'P111 copied integration lost {parent}: {len(inst)}')
        declared=p110.module_ports(p110.strip_comments((rtl/(parent+'.sv')).read_text()),parent)
        for _,names in inst:
            if len(names)!=len(set(names)) or set(names)!=declared:
                raise p110.WiringError(f'P111 copied integration port drift {parent}')
        # Compare actual expressions as well as pin names: P110 alone does
        # not detect two same-width nets connected to the wrong inputs.
        _,current=instance_bindings(toptext,parent)
        _,baseline=instance_bindings(inherited_top,parent)
        if current!=baseline:
            raise p110.WiringError(f'P111 copied integration binding drift {parent}')
    watched=p110.find_instances(toptext,WATCH,TOP)
    if len(watched)!=1:
        raise p110.WiringError(f'P111 requires exactly one wired monitor: found {len(watched)}')
    _,names=watched[0]
    if len(names)!=len(set(names)) or set(names)!=set(PINS):
        raise p110.WiringError('P111 monitor has missing/duplicate/unknown ports')
    m=re.search(r'\b'+re.escape(WATCH)+r'\s*#\s*\(',toptext)
    if not m:
        raise p110.WiringError('P111 monitor lost configurable max-wait parameter')
    _,actual=instance_bindings(toptext,WATCH)
    if actual!=PINS:
        differences={pin:(actual.get(pin),wire) for pin,wire in PINS.items()
                     if actual.get(pin)!=wire}
        raise p110.WiringError(f'P111 incorrect diagnostic pin wiring: {differences}')
    return {
      'schema':'A0-P111-STATIC-DIAGNOSTIC-PREFLIGHT-v1',
      'status':'PASS', 'sources_checked':previous['source_files']+2,
      'diagnostic_pins_checked':len(PINS),
      'old_p110_topology_status':previous['status'],
      'source_sha256':{TOP+'.sv':sha256(src).hexdigest(),WATCH+'.sv':sha256(mon).hexdigest()},
      'rtl_compiled':False, 'rtl_simulated':False, 'physical_gpu_proven':False,
    }


def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=ROOT)
    p.add_argument('--json',type=Path)
    a=p.parse_args()
    try: result=audit(a.root)
    except (p110.WiringError,OSError,UnicodeError) as exc:
        print('P111_PREFLIGHT_FAIL:',exc)
        return 1
    if a.json:
        a.json.parent.mkdir(parents=True,exist_ok=True)
        a.json.write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print('P111_PREFLIGHT_PASS: legacy graph +',len(PINS),'diagnostic signal mappings; NOT RTL compile')
    return 0

if __name__=='__main__': raise SystemExit(main())
