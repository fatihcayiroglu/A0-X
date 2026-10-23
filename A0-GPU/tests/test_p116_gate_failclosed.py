"""P116 gate policy tests using MOCKS; NOT actual RTL proof."""
import importlib.util
from pathlib import Path
import subprocess
import sys
from unittest import mock

import pytest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
spec=importlib.util.spec_from_file_location('a0_p116_gate',ROOT/'tests'/'run_p116_host_frame_audit_e2e.py')
assert spec and spec.loader
gate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def cp(code=0,stdout='',stderr=''):
    return subprocess.CompletedProcess([],code,stdout,stderr)


def check_policy(compiler,simulator=None):
    calls=[]
    def fake_run(argv,**kwargs):
        calls.append(argv)
        if argv[0]=='iverilog':
            if compiler[0]==0 and compiler[1]:Path(argv[argv.index('-o')+1]).touch()
            return cp(compiler[0],'','syntax error' if compiler[0] else '')
        if argv[0]=='vvp':
            assert simulator is not None
            if isinstance(simulator,Exception):raise simulator
            return simulator
        raise AssertionError('unexpected executable')
    with mock.patch.object(gate.shutil,'which',return_value='/fake/iverilog'), \
         mock.patch.object(gate.subprocess,'run',side_effect=fake_run):
        answer=gate.run()
    return answer,calls


def test_no_tools_is_not_run():
    with mock.patch.object(gate.shutil,'which',return_value=None):
        assert gate.run()==2


def test_compile_failure_is_fail():
    code,calls=check_policy((1,False))
    assert code==1 and len(calls)==1


def test_fake_compiler_exit_zero_without_product_is_fail():
    code,calls=check_policy((0,False))
    assert code==1 and len(calls)==1


@pytest.mark.parametrize('sim',[
    cp(1,gate.MARKER),cp(0,'wrong marker'),
    cp(0,gate.MARKER+'\nFATAL: still failed'),
    cp(0,'FATAL: file not found\n'+gate.MARKER),
])
def test_sim_failure_or_marker_spoof_is_fail(sim):
    code,calls=check_policy((0,True),sim)
    assert code==1 and len(calls)==2


def test_timeout_fails_closed():
    with pytest.raises(subprocess.TimeoutExpired):
        check_policy((0,True),subprocess.TimeoutExpired('vvp',180))


def test_mock_positive_branch_does_not_count_as_hardware_proof():
    code,calls=check_policy((0,True),cp(0,gate.MARKER))
    assert code==0 and len(calls)==2  # mocked only, NOT actual HDL evidence
    assert all('-g2012' in x for x in calls[:1])
    assert len([x for x in calls[0] if str(x).endswith('.sv')])>=19
    assert '-s' in calls[0]
    assert calls[1][0]=='vvp'
