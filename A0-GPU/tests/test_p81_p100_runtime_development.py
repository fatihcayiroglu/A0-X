"""P81-P100 bounded compute, driver-like queue, reproducibility acceptance.

Software reference tests ONLY, no synthesized/RTL behavior claim.
"""
import sys
import struct
import tempfile
import random
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from a0_nextgen_compute_p81_p85 import Kernel,dispatch,ComputeFault
from a0_nextgen_runtime_p86_p95 import *
from a0_nextgen_graphics_p56_p80 import Framebuffer,GraphicsState,Vertex,Texture,Shader
from a0_independent_graphics_oracle_p55 import render_commands
from a0_graphics_command_p43 import Command as OldCommand,CLEAR,TRIANGLE,PRESENT
from a0_p100_integrated_demo import run

class PrototypeRuntime(unittest.TestCase):
    def _kernel(self):
        return Kernel((('LOAD',3,0,0),('ADD',4,3,3),('STORE',0,0,4)),lanes=4)

    def test_p81_kernel_validate(self):
        with self.assertRaises(ComputeFault): Kernel((('JUMP',0,0,0),))
        with self.assertRaises(ComputeFault): Kernel((('ADD',0,1,2),),lanes=33)
        self.assertEqual(len(self._kernel().code),3)

    def test_p82_workgroups(self):
        r=dispatch(self._kernel(),list(range(12)),workgroups=3)
        self.assertEqual(r.data,tuple(2*x for x in range(12)))
        self.assertEqual(r.workgroups,3)

    def test_p83_masked_lanes(self):
        r=dispatch(self._kernel(),tuple(range(8)),workgroups=2,active_mask=0b0101)
        self.assertEqual(r.data,(0,1,4,3,8,5,12,7))
        self.assertEqual(r.executed_lanes,4)

    def test_p84_uniform_barrier_group_sum(self):
        k=Kernel((('LOAD',3,0,0),('BARRIER',0,0,0),('GROUP_SUM',4,3,0),('STORE',0,0,4)),lanes=4)
        r=dispatch(k,[1,2,3,4],workgroups=1)
        self.assertEqual(r.data,(10,10,10,10))
        self.assertEqual(r.barriers,1)

    def test_p85_global_mem_bounds(self):
        with self.assertRaises(ComputeFault):dispatch(self._kernel(),[1],workgroups=1)
        with self.assertRaises(ComputeFault):dispatch(self._kernel(),[1,2,3,4],active_mask=16)

    def test_p86_resource_allocation(self):
        r=ResourceTable(1)
        h=r.allocate(Buffer(b'ab'))
        self.assertEqual(r.get(h,Buffer).data,b'ab')
        with self.assertRaises(DeviceFault):r.allocate(Buffer(b'b'))

    def test_p87_stale_handle_rejection(self):
        r=ResourceTable(1);h=r.allocate(Buffer(b'a'))
        r.release(h);new=r.allocate(Buffer(b'b'))
        self.assertNotEqual(h,new)
        with self.assertRaises(DeviceFault):r.get(h)

    def test_p88_sealed_commands(self):
        b=CommandBuffer();b.append(Command('BARRIER'));b.seal()
        with self.assertRaises(DeviceFault):b.append(Command('BARRIER'))
        with self.assertRaises(DeviceFault):CommandBuffer().seal()

    def test_p89_queue_ordering(self):
        r=ResourceTable();q=SoftwareQueue(r)
        b=CommandBuffer();b.append(Command('BARRIER'));b.append(Command('BARRIER'));b.seal()
        self.assertEqual(q.submit(b),1)
        self.assertEqual([x[1] for x in q.logs],[0,1])

    def test_p90_fences(self):
        q=SoftwareQueue(ResourceTable());b=CommandBuffer();b.append(Command('BARRIER'));b.seal()
        self.assertFalse(q.completed)
        fence=q.submit(b)
        self.assertTrue(q.wait(fence))
        with self.assertRaises(DeviceFault):q.wait(fence+1)

    def test_p91_result_and_fault_propagation(self):
        r=ResourceTable();q=SoftwareQueue(r)
        b=CommandBuffer();b.append(Command('NOT_AN_OP'));b.seal()
        with self.assertRaises(DeviceFault):q.submit(b)
        self.assertEqual(q.logs[-1][2],'FAULT')

    def test_p92_upload_and_readback(self):
        r=ResourceTable();h=r.allocate(Buffer(b'old'));q=SoftwareQueue(r)
        b=CommandBuffer()
        for c in (Command('UPLOAD',h,b'new'),Command('BARRIER'),Command('READBACK',h)): b.append(c)
        b.seal();f=q.submit(b)
        self.assertEqual(q.outputs[f,2],b'new')

    def test_p93_host_packet_crc(self):
        frame=pack_trace(b'hello',kind=4,sequence=65535)
        self.assertEqual(unpack_trace(frame),(4,65535,b'hello'))
        corrupted=bytearray(frame);corrupted[-1]^=1
        with self.assertRaises(DeviceFault):unpack_trace(bytes(corrupted))

    def test_p94_malformed_payload_fails_closed(self):
        with self.assertRaises(DeviceFault):pack_trace(b'x'*65537)
        with self.assertRaises(DeviceFault):unpack_trace(b'A0T1')
        with self.assertRaises(DeviceFault):unpack_trace(pack_trace(b'foo')+b'junk')

    def test_p95_trace_reproducibility(self):
        r=ResourceTable();q=SoftwareQueue(r);b=CommandBuffer()
        b.append(Command('BARRIER'));b.seal();q.submit(b)
        self.assertEqual(pack_trace(str(q.logs).encode()),pack_trace(str(q.logs).encode()))

    def test_p96_independent_previous_oracle(self):
        fb=Framebuffer(8,8);fb.clear((0,0,0,1))
        verts=(Vertex(1,1,rgba=(1,0,0,1)),Vertex(6,1,rgba=(1,0,0,1)),Vertex(1,6,rgba=(1,0,0,1)))
        fb.draw(verts)
        cmd=[('CLEAR',OldCommand(CLEAR,1,0)),
             ('TRIANGLE',OldCommand(TRIANGLE,2,0xff0000,(1,1,6,1,1,6))),
             ('PRESENT',OldCommand(PRESENT,3))]
        self.assertEqual(fb.crc32(),render_commands(8,8,cmd)[0]['frame_crc32'])

    def test_p97_negative_mutation_detection(self):
        original=pack_trace(b'mutable')
        for position in (0,4,8,12,len(original)-1):
            dirty=bytearray(original);dirty[position]^=1
            with self.subTest(position=position):
                with self.assertRaises(DeviceFault):unpack_trace(bytes(dirty))

    def test_p98_randomized_texture_boundary(self):
        from a0_nextgen_graphics_p56_p80 import sample
        t=Texture(2,1,((1,0,0,1),(0,1,0,1)))
        r=random.Random(861234)
        for _ in range(300):
            u=r.uniform(-50,50)
            self.assertEqual(sample(t,(u,0.),mode='repeat'),sample(t,(u%1,0.),mode='repeat'))

    def test_p99_reproducible_graphics(self):
        from a0_nextgen_graphics_p56_p80 import GraphicsState
        t=(Vertex(0,0,rgba=(1,0,0,1)),Vertex(7,0,rgba=(1,0,0,1)),Vertex(0,7,rgba=(1,0,0,1)))
        a=Framebuffer(8,8);b=Framebuffer(8,8)
        a.draw(t,GraphicsState());b.draw(t,GraphicsState())
        self.assertEqual(a.rgb_bytes(),b.rgb_bytes())
        self.assertEqual(a.crc32(),b.crc32())

    def test_p100_integrated_demo(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            a=run(root/'a');b=run(root/'b')
            self.assertEqual(a,b)
            self.assertEqual(a['status'],'SOFTWARE_DEVELOPMENT_ONLY')
            self.assertFalse(a['rtl_simulated'])
            self.assertEqual(len((root/'a'/'a0_p100_software_only.ppm').read_bytes())-len(b'P6\n16 16\n255\n'),768)

if __name__=='__main__': unittest.main()
