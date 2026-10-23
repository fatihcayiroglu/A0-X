"""Extra property/negative checks for software-only P56-P100 prototype."""
import sys,random,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_nextgen_graphics_p56_p80 import *
from a0_independent_graphics_oracle_p55 import _covered
from a0_nextgen_runtime_p86_p95 import *

class AdversarialSoftwareChecks(unittest.TestCase):
    def test_legacy_triangle_pixel_parity_200_random(self):
        r=random.Random(1001)
        for _ in range(200):
            points=[(r.randint(-10,18),r.randint(-10,18)) for j in range(3)]
            vertices=tuple(Vertex(x,y) for x,y in points)
            direct={(x,y) for x,y,*_ in triangle_fragments(vertices,8,8)}
            legacy={(x,y) for y in range(8) for x in range(8) if _covered(*points,x,y)}
            self.assertEqual(direct,legacy,points)

    def test_two_unbarriered_writes_are_rejected(self):
        table=ResourceTable();h=table.allocate(Buffer(b'old'))
        commands=CommandBuffer()
        commands.append(Command('UPLOAD',h,b'first'))
        commands.append(Command('UPLOAD',h,b'second'))
        commands.seal()
        with self.assertRaisesRegex(DeviceFault,'hazard'):
            SoftwareQueue(table).submit(commands)

    def test_wrong_resource_type_rejected(self):
        table=ResourceTable();h=table.allocate(Buffer(b'data'))
        commands=CommandBuffer()
        commands.append(Command('DRAW',h,([],GraphicsState())))
        commands.seal()
        with self.assertRaisesRegex(DeviceFault,'type'):
            SoftwareQueue(table).submit(commands)

    def test_shader_undefined_source_and_excessive_budget_rejected(self):
        with self.assertRaises(ValueError):
            Shader((('ADD','r0','r1','one'),))
        with self.assertRaises(ValueError):
            Shader((('ADD','r0','color','one'),),budget=33)

    def test_nonfinite_sampler_and_wrong_depth_policy_rejected(self):
        t=Texture(1,1,((1,0,0,1),))
        with self.assertRaises(ValueError):sample(t,(float('nan'),0))
        fb=Framebuffer(4,4)
        tri=(Vertex(0,0),Vertex(4,0),Vertex(0,4))
        with self.assertRaises(ValueError):fb.draw(tri,GraphicsState(depth_compare='never-bogus'))

    def test_buffer_fault_does_not_get_false_positive_pass(self):
        table=ResourceTable(1);h=table.allocate(Buffer(b'orig'))
        cmds=CommandBuffer()
        cmds.append(Command('UPLOAD',h,b'new'))
        cmds.append(Command('READBACK',h))  # hazard, missing barrier
        cmds.seal()
        q=SoftwareQueue(table)
        with self.assertRaises(DeviceFault):q.submit(cmds)
        self.assertEqual(q.logs[-1][2],'FAULT')
        self.assertNotIn((1,1),q.outputs)

if __name__=='__main__':unittest.main()
