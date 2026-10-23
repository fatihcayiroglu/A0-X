"""Independent P130 evidence rejection checks, not a simulator substitute."""
import importlib.util
import itertools
import random
from pathlib import Path
import tempfile
import unittest

P = Path(__file__).resolve().parents[1]/'tools'/'a0_p130_graphics_synthesis.py'
spec=importlib.util.spec_from_file_location('a0_p130_graphics_synthesis',P)
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def valid_netlist():
    return {'modules':{'a0_triangle_scissor_depth_blend_p102':{
        'ports':{'clk':{'direction':'input'}},
        'cells':{'a':{'type':'$_AND_'},'b':{'type':'$_DFF_P_'}}}}}


def edge_64(ax,ay,bx,by,px2,py2):
    return (bx-ax)*(py2-2*ay) - (by-ay)*(px2-2*ax)


def signed_clip(value,bits):
    assert -(1<<(bits-1)) <= value < (1<<(bits-1)), (value,bits)
    return value


class P130Tests(unittest.TestCase):
    def test_accept_synthesis(self):
        r=mod.summarize_netlist(valid_netlist())
        self.assertEqual(r['generic_cell_count'],2)
        self.assertFalse(r['physical_gpu_qualified'])

    def test_reject_missing_top(self):
        with self.assertRaisesRegex(ValueError,'missing synthesized top'):
            mod.summarize_netlist({'modules':{}})

    def test_reject_empty_logic(self):
        j=valid_netlist();j['modules']['a0_triangle_scissor_depth_blend_p102']['cells']={}
        with self.assertRaisesRegex(ValueError,'optimized away'):mod.summarize_netlist(j)

    def test_reject_latch(self):
        j=valid_netlist();j['modules']['a0_triangle_scissor_depth_blend_p102']['cells']['a']['type']='$_DLATCH_P_'
        with self.assertRaisesRegex(ValueError,'latch'):mod.summarize_netlist(j)

    def test_reject_bad_io(self):
        j=valid_netlist();j['modules']['a0_triangle_scissor_depth_blend_p102']['ports']={}
        with self.assertRaisesRegex(ValueError,'I/O'):mod.summarize_netlist(j)

    def test_reject_missing_witness(self):
        with self.assertRaisesRegex(ValueError,'witness'):mod.validate_witness('')

    def test_reject_duplicated_witness(self):
        with self.assertRaisesRegex(ValueError,'duplicated'):
            mod.validate_witness(mod.WITNESS+'\n'+mod.WITNESS)

    def test_accept_exact_witness(self):
        out='P130_P38_CYCLES=14000\nP130_P38_TRIANGLES=196\nP130_P38_PIXEL_EVENTS=33\nP130_P38_DONE_EVENTS=196\n'+mod.WITNESS+'\n'
        self.assertEqual(mod.validate_witness(out)['triangles'],196)

    def test_exact_math_range_at_full_16bit_coordinates(self):
        verts=(-32768,-32767,-3,0,1,32766,32767)
        px2_vals=(-65536,-1,1,65533,65534)
        for a,b,p in itertools.product(verts,verts,px2_vals):
            signed_clip(b-a,17)
            signed_clip(p-2*a,18)

    def test_exact_products_and_cross_difference_random(self):
        rng=random.Random(130)
        for i in range(20000):
            ax,ay,bx,by=(rng.randint(-32768,32767) for _ in range(4))
            px2=rng.choice((rng.randint(0,32766)*2+1, rng.randint(-32768,32767)*2))
            py2=rng.choice((rng.randint(0,32766)*2+1, rng.randint(-32768,32767)*2))
            dx=signed_clip(bx-ax,17)
            dy=signed_clip(by-ay,17)
            rx=signed_clip(px2-2*ax,18)
            ry=signed_clip(py2-2*ay,18)
            a=signed_clip(dx*ry,35)
            b=signed_clip(dy*rx,35)
            cross=signed_clip(a-b,36)
            self.assertEqual(cross,edge_64(ax,ay,bx,by,px2,py2))

    def test_full_chain_sources_are_present_in_synth(self):
        script=mod.command_synth(Path('netlist.json'))
        self.assertIn('a0_triangle_scissor_depth_blend_p102',script)
        self.assertIn('a0_triangle_coverage_p38.sv',script)
        self.assertIn('FRAME_WIDTH 4',script)
        self.assertIn('FRAME_HEIGHT 4',script)
        self.assertIn('check -assert',script)

    def test_missing_real_tools_not_run(self):
        with tempfile.TemporaryDirectory() as td:
            ret=mod.run(Path(td),iverilog='missing-A0X-iverilog',vvp='missing-A0X-vvp',yosys='missing-A0X-yosys')
            self.assertEqual(ret,2)
            import json
            j=json.loads((Path(td)/'p130_qualification.json').read_text())
            self.assertEqual(j['status'],'NOT_RUN')
            self.assertFalse(j['simulated_actual_rtl'])
            self.assertFalse(j['synthesized_full_p102'])
            self.assertFalse(j['physical_gpu_qualified'])


if __name__=='__main__':unittest.main()