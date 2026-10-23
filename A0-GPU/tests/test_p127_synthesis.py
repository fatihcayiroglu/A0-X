"""P127 independent fail-closed evidence parser tests (not RTL)."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / 'tools' / 'a0_p127_synthesis.py'
spec = importlib.util.spec_from_file_location('p127', MODULE_PATH)
p127 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p127)


def netlist(cell_type='$_AND_', count=2, top='top'):
    return {'modules': {top: {'attributes': {'top': '00000000000000000000000000000001'},
            'ports': {'a': {'direction':'input','bits':[1]}, 'b': {'direction':'output','bits':[2]}},
            'cells': {f'x{i}': {'type': cell_type} for i in range(count)}}}}

class TestP127(unittest.TestCase):
    def test_counts_generic_cells(self):
        result = p127.summarize_netlist(netlist(), 'top')
        self.assertEqual(result['cell_count'], 2)
        self.assertEqual(result['latch_count'], 0)
    def test_unknown_top_rejected(self):
        with self.assertRaises(ValueError): p127.summarize_netlist(netlist(), 'missing')
    def test_no_cells_rejected(self):
        with self.assertRaises(ValueError): p127.summarize_netlist(netlist(count=0), 'top')
    def test_latch_rejected(self):
        with self.assertRaises(ValueError): p127.summarize_netlist(netlist('$_DLATCH_P_',1),'top')
    def test_unmapped_rtl_rejected(self):
        with self.assertRaises(ValueError): p127.summarize_netlist(netlist('$mem_v2',1),'top')
    def test_missing_top_flag_rejected(self):
        x=netlist();x['modules']['top']['attributes'].clear()
        with self.assertRaises(ValueError): p127.summarize_netlist(x,'top')
    def test_command_parameters(self):
        s=p127.command_for('test',Path('rtl/top.sv'),7,Path('out.json'))
        self.assertIn('hierarchy -check -top test -chparam FIFO_DEPTH 7',s)
        self.assertIn('check -assert',s)
    def test_no_yosys_must_fail_closed(self):
        with tempfile.TemporaryDirectory() as d:
            result=p127.run(Path(d), only='p68_depth_compare', yosys='definitely-not-a-real-executable')
            self.assertEqual(result,2)
            import json
            j=json.loads((Path(d)/'p127_synthesis.json').read_text())
            self.assertEqual(j['status'],'FAIL')
            self.assertEqual(j['targets'][0]['status'],'NOT_RUN')
            self.assertFalse(j['physical_gpu_qualified'])

if __name__ == '__main__': unittest.main()