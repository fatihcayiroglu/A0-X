"""P131 strict report parser tests, not simulated/real FPGA execution."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'tools' / 'a0_p131_ecp5_fit.py'
spec = importlib.util.spec_from_file_location('a0_p131_ecp5_fit', SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def fake_route():
    return {"utilization": {
        "TRELLIS_SLICE": {"used": 121, "available": 41820},
        "TRELLIS_IO": {"used": 12, "available": 205},
        "DP16KD": {"used": 2, "available": 208},
        "MULT18X18D": {"used": 1, "available": 156}},
        "fmax": {"clk": {"achieved": 11.24, "constraint": 1.0}}}


def fake_netlist():
    return {"modules": {mod.TOP: {"cells": {"a": {"type": "LUT4"}, "b": {"type": "TRELLIS_FF"}},
                                "ports": {"clk": {"direction": "input", "bits": [1]}}}}}


class P131ParserTests(unittest.TestCase):
    def test_route_pass(self):
        x = mod.summarize_route(fake_route())
        self.assertTrue(x['internal_timing_met'])
        self.assertEqual(x['resources']['TRELLIS_SLICE']['used'], 121)

    def test_missing_resources(self):
        r = fake_route(); del r['utilization']['TRELLIS_SLICE']
        with self.assertRaisesRegex(ValueError, 'missing real'):
            mod.summarize_route(r)

    def test_overcapacity(self):
        r = fake_route(); r['utilization']['TRELLIS_SLICE']['used'] = 99999
        with self.assertRaisesRegex(ValueError, 'overcapacity'):
            mod.summarize_route(r)

    def test_bool_not_integer(self):
        r = fake_route(); r['utilization']['TRELLIS_IO']['used'] = True
        with self.assertRaisesRegex(ValueError, 'malformed'):
            mod.summarize_route(r)

    def test_zero_logic(self):
        r = fake_route(); r['utilization']['TRELLIS_SLICE']['used'] = 0
        with self.assertRaisesRegex(ValueError, 'optimized'):
            mod.summarize_route(r)

    def test_missing_clock(self):
        r = fake_route(); r['fmax'] = {}
        with self.assertRaisesRegex(ValueError, 'no routed'):
            mod.summarize_route(r)

    def test_timing_failure(self):
        r = fake_route(); r['fmax']['clk']['achieved'] = 0.9
        with self.assertRaisesRegex(ValueError, 'timing failed'):
            mod.summarize_route(r)

    def test_clock_constraint_change(self):
        r = fake_route(); r['fmax']['clk']['constraint'] = 0.3
        with self.assertRaisesRegex(ValueError, 'changed constraint'):
            mod.summarize_route(r)

    def test_nan_clock(self):
        r = fake_route(); r['fmax']['clk']['achieved'] = float('nan')
        with self.assertRaisesRegex(ValueError, 'invalid clock'):
            mod.summarize_route(r)

    def test_netlist(self):
        self.assertEqual(mod.summarize_mapped_netlist(fake_netlist())['mapped_cell_count'], 2)

    def test_hierarchy_rejected(self):
        j = fake_netlist(); j['modules'][mod.TOP]['cells']['a']['type'] = 'a0_p70_rgb_blend'
        with self.assertRaisesRegex(ValueError, 'unmapped'):
            mod.summarize_mapped_netlist(j)

    def test_unmapped_rejected(self):
        j = fake_netlist(); j['modules'][mod.TOP]['cells']['a']['type'] = '$mul'
        with self.assertRaisesRegex(ValueError, 'unmapped'):
            mod.summarize_mapped_netlist(j)

    def test_exact_85k_commands(self):
        c = mod.nextpnr_args('nextpnr-ecp5', Path('a.json'), Path('a.config'), Path('a.report'))
        self.assertIn('--85k', c)
        self.assertIn('CABGA756', c)
        self.assertIn('--speed', c)
        self.assertIn('--lpf-allow-unconstrained', c)
        self.assertNotIn('--timing-allow-fail', c)
        self.assertIn('synth_ecp5', mod.yosys_script(Path('a.json')))
        self.assertIn('-chparam FRAME_WIDTH 4', mod.yosys_script(Path('a.json')))

    def test_missing_tool_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = mod.run(Path(tmp), yosys='no-a0x-yosys-p131', nextpnr='no-a0x-nextpnr-p131')
            self.assertEqual(res, 2)
            x = json.loads((Path(tmp) / 'p131_ecp5_qualification.json').read_text())
            self.assertEqual(x['status'], 'NOT_RUN')
            self.assertFalse(x['physical_gpu_qualified'])


if __name__ == '__main__':
    unittest.main()