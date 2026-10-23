"""P111 static preflight mutation tests. Not an HDL compile/behavior gate."""
import importlib.util
from pathlib import Path
import shutil

import pytest

ROOT=Path(__file__).resolve().parents[1]
TOOL=ROOT/'tools'/'a0_p111_rtl_diagnostic_preflight.py'
spec=importlib.util.spec_from_file_location('p111_preflight',TOOL)
assert spec and spec.loader
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

@pytest.fixture
def sources(tmp_path):
    g=tmp_path/'rtl'/'graphics'
    g.mkdir(parents=True)
    for source in (*mod.p110.SOURCES,mod.TOP+'.sv',mod.WATCH+'.sv'):
        shutil.copy(ROOT/'rtl'/'graphics'/source,g/source)
    return tmp_path


def mutate(root,path,old,new):
    p=root/'rtl'/'graphics'/path
    data=p.read_text()
    assert old in data
    p.write_text(data.replace(old,new,1))


def test_original_p111_wiring():
    out=mod.audit(ROOT)
    assert out['status']=='PASS'
    assert out['sources_checked']==16
    assert out['diagnostic_pins_checked']==17
    assert out['rtl_compiled'] is False


def test_missing_monitor_fails(sources):
    (sources/'rtl'/'graphics'/(mod.WATCH+'.sv')).unlink()
    with pytest.raises(OSError): mod.audit(sources)


def test_swapped_same_width_command_tag_fails(sources):
    mutate(sources,mod.TOP+'.sv','.cmd_tag(cmd_tag)',
           '.cmd_tag(completion_tag)')
    with pytest.raises(mod.p110.WiringError,match='binding drift'):
        mod.audit(sources)


def test_swapped_same_width_completion_ready_fails(sources):
    mutate(sources,mod.TOP+'.sv','.completion_ready(completion_ready)',
           '.completion_ready(cmd_ready)')
    with pytest.raises(mod.p110.WiringError,match='binding drift'):
        mod.audit(sources)


def test_missing_watcher_instantiation_fails(sources):
    mutate(sources,mod.TOP+'.sv',mod.WATCH+' #(', 'not_watchdog #(')
    with pytest.raises(mod.p110.WiringError,match='exactly one wired monitor'):
        mod.audit(sources)


def test_monitor_missing_output_fails(sources):
    mutate(sources,mod.TOP+'.sv',
           '.tag_mismatch_count(diagnostic_tag_mismatches),','')
    with pytest.raises(mod.p110.WiringError,match='missing/duplicate/unknown'):
        mod.audit(sources)


def test_duplicate_monitor_pin_fails(sources):
    mutate(sources,mod.TOP+'.sv',
           '.fault_sticky(diagnostic_fault),',
           '.fault_sticky(diagnostic_fault),.fault_sticky(diagnostic_fault),')
    with pytest.raises(mod.p110.WiringError,match='missing/duplicate/unknown'):
        mod.audit(sources)


def test_changed_monitor_declaration_fails(sources):
    mutate(sources,mod.WATCH+'.sv', 'output logic fault_sticky, pending,',
           'output logic bad_fault_sticky, pending,')
    with pytest.raises(mod.p110.WiringError,match='port contract mismatch'):
        mod.audit(sources)


def test_inherited_preflight_detects_existing_module_breakage(sources):
    mutate(sources,'a0_host_fragment_dual_bank_bridge_p106.sv',
           '.cmd_depth_op(cmd_depth_op)', '.illegal_port(cmd_depth_op)')
    with pytest.raises(mod.p110.WiringError):mod.audit(sources)


def test_original_sources_unchanged_under_audit(sources):
    before=[(p.name,p.read_bytes()) for p in (sources/'rtl'/'graphics').iterdir()]
    mod.audit(sources)
    after=[(p.name,p.read_bytes()) for p in (sources/'rtl'/'graphics').iterdir()]
    assert sorted(before)==sorted(after)


def test_monitor_specific_same_width_tag_swap_fails(sources):
    p=sources/'rtl'/'graphics'/(mod.TOP+'.sv')
    s=p.read_text()
    marker=mod.WATCH+' #('
    a,b=s.split(marker,1)
    assert '.cmd_tag(cmd_tag)' in b
    p.write_text(a+marker+b.replace('.cmd_tag(cmd_tag)',
                                '.cmd_tag(completion_tag)',1))
    with pytest.raises(mod.p110.WiringError,match='incorrect diagnostic pin'):
        mod.audit(sources)
