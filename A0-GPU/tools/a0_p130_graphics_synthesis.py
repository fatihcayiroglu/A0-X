#!/usr/bin/env python3
"""P130 narrow-raster real RTL equivalence and full P102 generic synthesis.

No physical FPGA resource fit, placement, timing, IO constraints or GPU
qualification is claimed. Strict fail-closed simulator/synthesizer evidence.
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
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
P38 = ROOT / 'A0-GPU/rtl/graphics/a0_triangle_coverage_p38.sv'
REFERENCE = ROOT / 'A0-GPU/tests/rtl/a0_p130_p38_reference.sv'
TB = ROOT / 'A0-GPU/tests/rtl/a0_p130_p38_width_equivalence_tb.sv'
P102 = ROOT / 'A0-GPU/rtl/graphics/a0_triangle_scissor_depth_blend_p102.sv'
SOURCES = (
    P38,
    ROOT/'A0-GPU/rtl/graphics/a0_p59_scissor_coverage.sv',
    ROOT/'A0-GPU/rtl/graphics/a0_p68_depth_compare.sv',
    ROOT/'A0-GPU/rtl/graphics/a0_p70_rgb_blend.sv',
    P102,
)
WITNESS='P130_P38_EXACT_WIDTH_RTL_EQUIVALENCE_PASS'


def summarize_netlist(data: dict, top: str = 'a0_triangle_scissor_depth_blend_p102') -> dict:
    if not isinstance(data, dict): raise ValueError('missing JSON netlist')
    mods = data.get('modules')
    if not isinstance(mods, dict) or top not in mods: raise ValueError('missing synthesized top')
    entry=mods[top]
    cells=entry.get('cells')
    if not isinstance(cells, dict) or not cells: raise ValueError('netlist optimized away')
    kinds={}
    for cell in cells.values():
        typ=cell.get('type','')
        if not isinstance(typ,str) or not typ: raise ValueError('bad cell type')
        if 'latch' in typ.lower() or typ.startswith('$mem'):
            raise ValueError('unmapped latch or memory cell')
        if not typ.startswith('$_'):
            raise ValueError(f'unflattened / non-generic cell: {typ}')
        kinds[typ]=kinds.get(typ,0)+1
    if not entry.get('ports'): raise ValueError('missing I/O ports')
    return {'generic_cell_count': len(cells), 'generic_cell_types': kinds,
            'netlist_flattened': True, 'device_mapped': False,
            'physical_gpu_qualified': False}


def validate_witness(stdout: str) -> dict:
    if stdout.count(WITNESS)!=1:
        raise ValueError('real RTL differential pass witness missing or duplicated')
    fields={}
    for field in ('CYCLES','TRIANGLES','PIXEL_EVENTS','DONE_EVENTS'):
        found=re.findall(r'^P130_P38_'+field+r'=(\d+)$',stdout,re.MULTILINE)
        if len(found)!=1: raise ValueError('missing/duplicate witness '+field)
        fields[field.lower()]=int(found[0])
    if fields['cycles'] < 13000 or fields['triangles']!=196 or fields['done_events']<150:
        raise ValueError('inadequate differential coverage')
    return fields


def command_synth(netlist: Path) -> str:
    files=' '.join(str(p) for p in SOURCES)
    return '; '.join([
        f'read_verilog -sv {files}',
        'hierarchy -check -top a0_triangle_scissor_depth_blend_p102 -chparam FRAME_WIDTH 4 -chparam FRAME_HEIGHT 4',
        'synth -flatten -top a0_triangle_scissor_depth_blend_p102',
        'check -assert',
        f'write_json {netlist}',
    ])


def run(evidence: Path, iverilog='iverilog', vvp='vvp', yosys='yosys', timeout=420) -> int:
    evidence.mkdir(parents=True,exist_ok=True)
    found={k:shutil.which(v) for k,v in [('iverilog',iverilog),('vvp',vvp),('yosys',yosys)]}
    report={'milestone':'P130','schema':1,'status':'FAIL',
            'simulated_actual_rtl':False,'synthesized_full_p102':False,
            'fpga_placed_routed':False,'fpga_timing_qualified':False,
            'physical_board_tested':False,'physical_gpu_qualified':False,
            'tools_present': all(found.values()),'tools':found, 'equivalence':{},'synthesis':{}}
    try:
        if not all(found.values()):
            report['status']='NOT_RUN';report['reason']='missing genuine Icarus or Yosys executable'
            return 2
        sources=[P38,REFERENCE,TB,*SOURCES[1:]]
        for s in sources:
            if not s.is_file():
                report['reason']=f'missing source {s}';return 1
        report['source_sha256']={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
        binary=evidence/'p130_width_equiv.vvp'
        compile_cmd=[found['iverilog'],'-g2012','-s','a0_p130_p38_width_equivalence_tb','-o',str(binary),str(P38),str(REFERENCE),str(TB)]
        c=subprocess.run(compile_cmd,cwd=ROOT,capture_output=True,text=True,timeout=timeout)
        (evidence/'p130_compile.log').write_text(c.stdout+'\n'+c.stderr)
        report['equivalence']['compile_exit_code']=c.returncode
        if c.returncode!=0 or not binary.is_file():
            report['reason']='real Icarus compile failed';return 1
        v=subprocess.run([found['vvp'],str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=timeout)
        (evidence/'p130_simulation.log').write_text(v.stdout+'\n'+v.stderr)
        report['equivalence']['simulate_exit_code']=v.returncode
        if v.returncode!=0: report['reason']='real Icarus simulation failed';return 1
        report['equivalence'].update(validate_witness(v.stdout))
        report['simulated_actual_rtl']=True
        netlist=evidence/'p130_full_p102_netlist.json'
        yc=[found['yosys'],'-Q','-T','-p',command_synth(netlist)]
        y=subprocess.run(yc,cwd=ROOT,capture_output=True,text=True,timeout=timeout)
        (evidence/'p130_yosys.log').write_text(y.stdout+'\nSTDERR:\n'+y.stderr)
        report['synthesis']['yosys_exit_code']=y.returncode
        if y.returncode!=0 or not netlist.is_file():
            report['reason']='full 4x4 P102 generic RTL synthesis failed';return 1
        summary=summarize_netlist(json.loads(netlist.read_text()))
        report['synthesis'].update(summary)
        report['synthesized_full_p102']=True
        report['status']='PASS'
        return 0
    except (subprocess.TimeoutExpired,ValueError,OSError,KeyError,json.JSONDecodeError) as exc:
        report['reason']=f'{type(exc).__name__}: {exc}'
        return 1
    finally:
        (evidence/'p130_width_equiv.vvp').unlink(missing_ok=True)
        (evidence/'p130_full_p102_netlist.json').unlink(missing_ok=True)
        report['generated_at_utc']=datetime.now(timezone.utc).isoformat()
        (evidence/'p130_qualification.json').write_text(json.dumps(report,indent=2)+'\n')
        print(f"P130_{report['status']}: sim={report['simulated_actual_rtl']}, full_P102_generic_synth={report['synthesized_full_p102']}, physical_gpu={report['physical_gpu_qualified']}")

if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--evidence',type=Path,default=Path('EVIDENCE/P130/qualification'))
    p.add_argument('--timeout',type=int,default=420)
    a=p.parse_args()
    sys.exit(run(a.evidence,timeout=a.timeout))