"""P110 offline structural contract and fail-closed mutation tests.

These are NOT RTL simulation tests. They assert that the preflight catches
missing hierarchy edges or broken connections before a real HDL gate runs.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil

import pytest

ROOT = Path(__file__).resolve().parents[1]
FILE = ROOT/'tools'/'a0_p110_rtl_wiring_preflight.py'
spec = importlib.util.spec_from_file_location('a0_p110_preflight', FILE)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

@pytest.fixture
def copied_tree(tmp_path: Path) -> Path:
    g = tmp_path/'rtl'/'graphics'
    g.mkdir(parents=True)
    for name in mod.SOURCES:
        shutil.copyfile(ROOT/'rtl'/'graphics'/name, g/name)
    return tmp_path


def mutate(root: Path, filename: str, old: str, new: str) -> None:
    p = root/'rtl'/'graphics'/filename
    s = p.read_text()
    assert old in s, f'missing fixture code fragment: {old}'
    p.write_text(s.replace(old, new, 1))


def test_original_sources_are_structurally_consistent():
    r = mod.audit(ROOT)
    assert r['status'] == 'PASS'
    assert r['qualification'] == 'SOURCE_STRUCTURE_ONLY_NOT_ELABORATED'
    assert r['source_files'] == 14
    assert r['instances_checked'] == 13
    assert r['named_connections_checked'] == 243
    assert r['rtl_compiled'] is False and r['rtl_simulated'] is False
    assert r['physical_gpu_proven'] is False


def test_missing_source_fails(copied_tree):
    (copied_tree/'rtl'/'graphics'/mod.SOURCES[0]).unlink()
    with pytest.raises(mod.WiringError, match='missing source'):
        mod.audit(copied_tree)


def test_wrong_declared_module_name_fails(copied_tree):
    mutate(copied_tree, 'a0_host_command_rx_p106.sv',
           'module a0_host_command_rx_p106', 'module unexpected_decoder')
    with pytest.raises(mod.WiringError, match='expected module'):
        mod.audit(copied_tree)


def test_unknown_named_port_fails(copied_tree):
    mutate(copied_tree, 'a0_host_fragment_dual_bank_bridge_p106.sv',
           '.cmd_depth_op(cmd_depth_op)', '.cmd_depth_foo(cmd_depth_op)')
    with pytest.raises(mod.WiringError, match='unknown='):
        mod.audit(copied_tree)


def test_missing_named_port_fails(copied_tree):
    mutate(copied_tree, 'a0_host_fragment_dual_bank_bridge_p106.sv',
           '.cmd_depth_op(cmd_depth_op),', '')
    with pytest.raises(mod.WiringError, match='missing='):
        mod.audit(copied_tree)


def test_duplicate_named_port_fails(copied_tree):
    mutate(copied_tree, 'a0_host_fragment_dual_bank_bridge_p106.sv',
           '.cmd_depth_op(cmd_depth_op),',
           '.cmd_depth_op(cmd_depth_op),.cmd_depth_op(cmd_depth_op),')
    with pytest.raises(mod.WiringError, match='duplicate='):
        mod.audit(copied_tree)


def test_empty_port_binding_fails(copied_tree):
    mutate(copied_tree, 'a0_host_fragment_dual_bank_bridge_p106.sv',
           '.cmd_depth_op(cmd_depth_op)', '.cmd_depth_op()')
    with pytest.raises(mod.WiringError, match='empty port'):
        mod.audit(copied_tree)


def test_positional_port_binding_fails(copied_tree):
    mutate(copied_tree, 'a0_host_fragment_dual_bank_bridge_p106.sv',
           '.cmd_depth_op(cmd_depth_op)', 'cmd_depth_op')
    with pytest.raises(mod.WiringError, match='positional'):
        mod.audit(copied_tree)


def test_wildcard_connection_fails(copied_tree):
    mutate(copied_tree, 'a0_host_fragment_dual_bank_bridge_p106.sv',
           '.cmd_depth_op(cmd_depth_op)', '.*')
    with pytest.raises(mod.WiringError, match='wildcard'):
        mod.audit(copied_tree)


def test_missing_expected_instance_fails(copied_tree):
    mutate(copied_tree, 'a0_host_fragment_dual_bank_bridge_p106.sv',
           'a0_host_tx_fair_arbiter_p49 mux (', 'unreviewed_mux mux (')
    with pytest.raises(mod.WiringError, match='expected 1 instances, found 0'):
        mod.audit(copied_tree)


def test_unreviewed_known_dependency_fails(copied_tree):
    source = 'a0_host_fragment_dual_bank_bridge_p106.sv'
    path = copied_tree/'rtl'/'graphics'/source
    text = path.read_text()
    text = text.replace('endmodule',
        'a0_p70_rgb_blend extra (.source_rgb(cmd_color));\nendmodule', 1)
    path.write_text(text)
    with pytest.raises(mod.WiringError, match='unreviewed dependency'):
        mod.audit(copied_tree)


def test_comment_cannot_restore_a_missing_instance(copied_tree):
    source = 'a0_host_fragment_dual_bank_bridge_p106.sv'
    path = copied_tree/'rtl'/'graphics'/source
    text = path.read_text().replace('a0_host_tx_fair_arbiter_p49 mux (',
                                    'a0_bad_mux mux (', 1)
    text = '// a0_host_tx_fair_arbiter_p49 spoof (.host_valid(tx_valid));\n'+text
    path.write_text(text)
    with pytest.raises(mod.WiringError, match='expected 1 instances, found 0'):
        mod.audit(copied_tree)


def test_changed_source_alters_sha256(copied_tree):
    before = mod.audit(copied_tree)
    source = 'a0_host_command_rx_p106.sv'
    with (copied_tree/'rtl'/'graphics'/source).open('a') as fd:
        fd.write('\n// P110 mutation of comment only\n')
    after = mod.audit(copied_tree)
    assert before['source_sha256'][source] != after['source_sha256'][source]
    assert after['instances_checked'] == before['instances_checked']
