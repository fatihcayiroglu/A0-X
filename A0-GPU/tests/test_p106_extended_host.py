"""P106 positive/negative SOFTWARE oracle tests; not hardware simulation."""
import random
import struct
import sys
import unittest
import zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import Command,CLEAR,TRIANGLE,PRESENT,INVALID
from a0_host_protocol_p44 import encode_command,decode_result,ProtocolError
from a0_host_extended_p106 import (HostDraw,LEGACY_FRAGMENT,
    encode_extended_triangle,decode_host_command,ExtendedCommandStreamDecoder)
from a0_p102_fragment_reference import FragmentState,PixelTarget,blend_rgb
from a0_p106_host_fragment_reference import P106HostSession
from a0_frame_telemetry_p48 import decode_host_frames

V=(0,0,4,0,0,4)
def wire(op,tag,color=0,vertices=(0,)*6):
    return encode_command(Command(op,tag,color,vertices))
def extended(tag=1,color=0xff0000,depth=55,vertices=V,**s):
    state=FragmentState(**s)
    return encode_extended_triangle(HostDraw(Command(TRIANGLE,tag,color,vertices),depth,state))
def mutate_header(packet,offset,value):
    body=bytearray(packet[:52]);body[offset]=value
    return bytes(body)+struct.pack('<I',zlib.crc32(body))

class Protocol106(unittest.TestCase):
    def test_legacy_unchanged_and_fragment_reset_default(self):
        for op in (CLEAR,TRIANGLE,PRESENT,INVALID):
            c=Command(op,123,456 if op<=1 else 0,V if op==TRIANGLE else (0,)*6)
            p=encode_command(c)
            parsed=decode_host_command(p)
            self.assertEqual(parsed.command,c)
            self.assertEqual(parsed.state,LEGACY_FRAGMENT)
            self.assertEqual(parsed.depth,0xffffff)

    def test_v2_exact_shape_and_crc(self):
        p=extended(scissor=(1,2,3,4),blend=True,depth_op=2,depth_write=True,alpha=97)
        self.assertEqual(len(p),56)
        self.assertEqual(p[:6],b'A0GC\x02\x01')
        self.assertEqual(p[28:32],b'7\x00\x00\x00')
        self.assertEqual(p[32],0x1e)
        self.assertEqual(p[33],97)
        self.assertEqual(zlib.crc32(p[:52]),int.from_bytes(p[52:],'little'))
        parsed=decode_host_command(p)
        self.assertEqual(parsed.state,FragmentState(2,True,True,97,(1,2,3,4)))

    def test_randomized_canonical_roundtrip(self):
        r=random.Random(106)
        for _ in range(350):
            s=FragmentState(r.randrange(4),bool(r.randrange(2)),bool(r.randrange(2)),
                            r.randrange(256),(r.randrange(16),r.randrange(16),
                            r.randrange(1,17),r.randrange(1,17)) if r.randrange(2) else None)
            c=Command(TRIANGLE,r.randrange(65536),r.randrange(0x1000000),
                      tuple(r.randrange(-32768,32768) for _ in range(6)))
            d=HostDraw(c,r.randrange(0x1000000),s)
            self.assertEqual(decode_host_command(encode_extended_triangle(d)),d)

    def test_crc_mismatch_rejected(self):
        p=bytearray(extended());p[39]^=32
        with self.assertRaisesRegex(ProtocolError,'CRC'):
            decode_host_command(bytes(p))

    def test_reserved_and_invalid_fields_rejected_even_if_crc_valid(self):
        good=extended()
        for i,b in ((5,2),(11,1),(24,1),(31,1),(32,0x80),(34,1),
                    (36,1),(44,1),(51,1)):
            with self.subTest(i=i):
                with self.assertRaises(ProtocolError):
                    decode_host_command(mutate_header(good,i,b))

    def test_scissor_zero_and_disabled_nonzero_rejected(self):
        good=extended(scissor=(1,1,2,3))
        for position in (40,42):
            bad=bytearray(good[:52]);bad[position]=0
            with self.assertRaises(ProtocolError):
                decode_host_command(bytes(bad)+struct.pack('<I',zlib.crc32(bad)))
        with self.assertRaises(ProtocolError):extended(scissor=(0,0,0,1))

    def test_v2_forbidden_clear_or_present(self):
        for op in (CLEAR,PRESENT,INVALID):
            bad=mutate_header(extended(),5,op)
            with self.assertRaises(ProtocolError):decode_host_command(bad)
            with self.assertRaises(ProtocolError):
                encode_extended_triangle(HostDraw(Command(op,2)))

    def test_reject_oversized_and_noninteger_settings(self):
        for kwargs in ({'alpha':256},{'alpha':True},{'depth_op':4},
                       {'depth_write':1},{'blend':1},{'scissor':(0,0,0,3)},
                       {'scissor':(-1,0,1,2)}):
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(ProtocolError):extended(**kwargs)
        with self.assertRaises(ProtocolError):
            encode_extended_triangle(HostDraw(Command(TRIANGLE,1,2,V),0x1000000))
        with self.assertRaises(ProtocolError):decode_host_command(b'')

    def test_mixed_stream_fragmentation(self):
        packets=[wire(CLEAR,1,0),extended(2,depth_op=2,scissor=(1,0,2,4)),
                 wire(TRIANGLE,3,4,V),wire(PRESENT,4),extended(5)]
        for seed in range(20):
            r=random.Random(seed);stream=b''.join(packets)
            dec=ExtendedCommandStreamDecoder();got=[]
            while stream:
                n=r.randrange(1,13)
                got.extend(dec.feed(stream[:n]));stream=stream[n:]
            self.assertEqual([x.command.tag for x in got],list(range(1,6)))
            self.assertEqual(dec.invalid_frames,0)
            self.assertEqual(len(dec.buffer),0)

    def test_stream_corruption_recovers_at_next_magic(self):
        bad=bytearray(extended());bad[20]^=1
        stream=wire(CLEAR,1)+bytes(bad)+wire(PRESENT,3)
        decoder=ExtendedCommandStreamDecoder()
        got=decoder.feed(stream)
        self.assertEqual([x.command.tag for x in got],[1,3])
        self.assertGreaterEqual(decoder.invalid_frames,1)

    def test_stream_never_dispatches_partial_extended(self):
        d=ExtendedCommandStreamDecoder();p=extended()
        self.assertEqual(d.feed(p[:55]),[])
        self.assertEqual(d.feed(p[55:])[0].command.tag,1)

    def test_unknown_version_and_garbage_recovery(self):
        d=ExtendedCommandStreamDecoder()
        data=b'junkA0GC\x09noise'+wire(CLEAR,29)
        self.assertEqual([x.command.tag for x in d.feed(data)],[29])
        self.assertEqual(d.invalid_frames,1)

    def test_decoder_input_type_rejected(self):
        d=ExtendedCommandStreamDecoder()
        for x in ('',None,bytearray()):
            with self.assertRaises(TypeError):d.feed(x)

class Pipeline106(unittest.TestCase):
    def setUp(self):
        self.s=P106HostSession(4,4)
    def issue(self,data):return decode_result(self.s.issue(data))
    def prepare(self,color=0x102030):
        self.assertTrue(self.issue(wire(CLEAR,1,color)).ok)

    def test_depth_less_rejects_farther_triangle(self):
        self.prepare()
        self.issue(extended(2,color=0xaabbcc,depth=10,depth_op=1,depth_write=True))
        self.issue(extended(3,color=0x223344,depth=20,depth_op=1,depth_write=True))
        bank=self.s.gpu.banks[self.s.gpu.render_bank]
        self.assertEqual(bank.pixel(0,0),(0xaabbcc,10))
        self.assertEqual(bank.pixel(3,3),(0x102030,0xffffff))

    def test_depth_equal_and_never(self):
        self.prepare()
        self.issue(extended(2,color=0x110000,depth=50,depth_op=1,depth_write=True))
        self.issue(extended(3,color=0x220000,depth=50,depth_op=1,depth_write=True))
        self.issue(extended(4,color=0x330000,depth=50,depth_op=2,depth_write=True))
        self.issue(extended(5,color=0x440000,depth=0,depth_op=3,depth_write=True))
        bank=self.s.gpu.banks[self.s.gpu.render_bank]
        self.assertEqual(bank.pixel(0,0),(0x330000,50))

    def test_scissor_applies_only_inside_box(self):
        self.prepare(0x111111)
        self.issue(extended(2,color=0xffffff,scissor=(1,1,2,2),depth_op=0,depth_write=False))
        b=self.s.gpu.banks[self.s.gpu.render_bank]
        self.assertEqual(b.pixel(1,1)[0],0xffffff)
        self.assertEqual(b.pixel(0,0)[0],0x111111)

    def test_blend_matches_independent_channel_formula(self):
        self.prepare(0x123456)
        self.issue(extended(2,color=0xabcdef,blend=True,alpha=91,
                            depth_op=0,depth_write=False))
        self.assertEqual(self.s.gpu.banks[self.s.gpu.render_bank].pixel(0,0)[0],
                         blend_rgb(0xabcdef,0x123456,91))

    def test_legacy_after_extended_does_not_inherit_state(self):
        self.prepare()
        self.issue(extended(2,color=0xff0000,depth=1,depth_op=1,
                            depth_write=True,scissor=(1,1,1,1),blend=True,alpha=0))
        self.issue(wire(TRIANGLE,3,0x00ff00,V))
        b=self.s.gpu.banks[self.s.gpu.render_bank]
        self.assertEqual(b.pixel(0,0)[0],0x00ff00)
        self.assertEqual(b.pixel(0,0)[1],0xffffff)

    def test_present_crc_with_mixed_v1_v2(self):
        self.prepare(0)
        self.issue(extended(2,color=0x445566,depth=2,depth_op=1,depth_write=True))
        self.assertTrue(self.issue(wire(PRESENT,3)).ok)
        pixels=self.s.drain(ready=lambda t:t%4!=0)
        expected=zlib.crc32(b''.join(p.color.to_bytes(3,'little') for p in pixels))
        frame=decode_host_frames(b''.join(self.s.telemetry))[0]
        self.assertEqual(frame['frame_crc'],expected)
        self.assertEqual(frame['good'],1)

    def test_invalid_extended_rejected_without_dispatch(self):
        before=list(self.s.tags)
        p=bytearray(extended());p[-1]^=1
        with self.assertRaises(ProtocolError):self.s.issue(bytes(p))
        self.assertEqual(self.s.tags,before)
        self.assertEqual(self.s.results,[])

    def test_rtl_wiring_and_compatibility_maintained(self):
        r=Path(__file__).resolve().parents[1]/'rtl/graphics'
        source=(r/'a0_host_fragment_dual_bank_bridge_p106.sv').read_text()
        self.assertEqual(source.count('a0_host_command_rx_p106 receiver'),1)
        for binding in ('.cmd_depth(cmd_depth)', '.cmd_depth_op(cmd_depth_op)',
                        '.cmd_depth_write(cmd_depth_write)',
                        '.cmd_blend_enable(cmd_blend_enable)',
                        '.cmd_scissor_enable(cmd_scissor_enable)',
                        '.stream_active(scan_active)'):
            self.assertIn(binding,source)
        self.assertNotIn('a0_host_command_rx_p45 receiver',source)

if __name__=='__main__':unittest.main()
