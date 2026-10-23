"""P101 regression: command buffer sealing and uint32 resource identity safety.

Software-only reference validation, not RTL or physical GPU qualification.
"""
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_nextgen_runtime_p86_p95 import (ResourceTable, Buffer, CommandBuffer, Command, DeviceFault, SoftwareQueue)
from a0_nextgen_graphics_p56_p80 import Framebuffer, GraphicsState, Vertex

class CommandIdentityHardening(unittest.TestCase):
    def test_sealed_commands_cannot_be_extended_by_public_getter(self):
        c=CommandBuffer();c.append(Command('BARRIER'));c.seal()
        with self.assertRaises((AttributeError,TypeError)):
            c.commands.append(Command('UPLOAD',999,b'bad'))
        self.assertEqual(len(c.commands),1)
        self.assertEqual(SoftwareQueue(ResourceTable()).submit(c),1)

    def test_sealed_properties_are_readonly(self):
        c=CommandBuffer();c.append(Command('BARRIER'));c.seal()
        with self.assertRaises(AttributeError):c.commands=tuple()
        with self.assertRaises(AttributeError):c.sealed=False

    def test_payload_snapshot_after_seal(self):
        resources=ResourceTable(); h=resources.allocate(Framebuffer(4,4))
        vertices=[Vertex(0,0), Vertex(3,0), Vertex(0,3)]
        state=GraphicsState(blending=False)
        c=CommandBuffer();c.append(Command('DRAW',h,(vertices,state)));c.seal()
        vertices.clear(); state.blending=True
        self.assertEqual(len(c.commands[0].payload[0]),3)
        self.assertFalse(c.commands[0].payload[1].blending)
        self.assertEqual(SoftwareQueue(resources).submit(c),1)

    def test_public_payload_reader_does_not_mutate_stored_command(self):
        c=CommandBuffer();c.append(Command('DRAW',8,([Vertex(0,0),Vertex(2,0),Vertex(0,2)],GraphicsState())));c.seal()
        getter=c.commands
        getter[0].payload[0].clear()
        getter[0].payload[1].cull='cw'
        self.assertEqual(len(c.commands[0].payload[0]),3)
        self.assertEqual(c.commands[0].payload[1].cull,'none')

    def test_sequence_stable_after_repeated_seal(self):
        c=CommandBuffer();c.append(Command('BARRIER'))
        self.assertEqual(c.seal(),c.seal())
        with self.assertRaises(DeviceFault):c.append(Command('BARRIER'))

    def test_generation_exhaustion_never_reanimates_early_handle(self):
        resources=ResourceTable(1)
        oldest=resources.allocate(Buffer(b'first'));resources.release(oldest)
        for _ in range(65534):
            handle=resources.allocate(Buffer(b'next'));resources.release(handle)
        with self.assertRaisesRegex(DeviceFault,'full|exhaust'):
            resources.allocate(Buffer(b'new'))
        with self.assertRaises(DeviceFault):resources.get(oldest)

    def test_generation_exhaustion_can_use_other_slot(self):
        resources=ResourceTable(2)
        # Fast-forward represents the end of the finite uint16 generation space.
        resources.generations[1]=65535
        final=resources.allocate(Buffer(b'last'));resources.release(final)
        new=resources.allocate(Buffer(b'other'))
        self.assertEqual(new&0xffff,2)
        with self.assertRaises(DeviceFault):resources.get(final)

    def test_allocated_handles_remain_uint32(self):
        resources=ResourceTable(2)
        for _ in range(20):
            h=resources.allocate(Buffer(b'x'))
            self.assertGreater(h,0)
            self.assertLessEqual(h,0xffffffff)
            resources.release(h)

if __name__=='__main__':unittest.main()
