"""P105 software behavioral tests. None are hardware simulation."""
import random
import sys
import unittest
import zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import Command, CLEAR, TRIANGLE, PRESENT, INVALID
from a0_host_protocol_p44 import (encode_command, decode_result, ProtocolError)
from a0_frame_telemetry_p48 import decode_host_frames
from a0_host_stream_p49 import HostStreamDecoder
from a0_p105_host_dual_bank_reference import P105HostSession
from a0_p102_fragment_reference import covered

V=(0,0,4,0,0,4)
def wire(op, tag, color=0, vertices=(0,)*6):
    return encode_command(Command(op,tag,color,vertices))
def crc(colors):
    return zlib.crc32(b''.join(int(c).to_bytes(3,'little') for c in colors))

class HostDoubleBankAcceptance(unittest.TestCase):
    def setUp(self):self.s=P105HostSession(4,4)
    def issue(self,op,tag,color=0,v=(0,)*6):
        return decode_result(self.s.issue(wire(op,tag,color,v)))
    def first(self,color=0x112233):
        self.assertTrue(self.issue(CLEAR,11,color).ok)
        self.assertTrue(self.issue(PRESENT,12).ok)
        self.assertTrue(self.s.gpu.active)

    def test_rx_frames_preserve_command_tags(self):
        self.assertEqual(self.issue(CLEAR,65535,3).tag,65535)
        self.assertEqual(self.issue(TRIANGLE,0,4,V).tag,0)
        self.assertEqual(self.s.tags,[65535,0])

    def test_invalid_p44_crc_refused_before_dispatch(self):
        data=bytearray(wire(CLEAR,1,2));data[-1]^=1
        with self.assertRaises(ProtocolError):self.s.issue(bytes(data))
        self.assertEqual(self.s.results,[])
        self.assertEqual(self.s.tags,[])

    def test_tri_before_clear_and_present_before_clear_errors(self):
        self.assertFalse(self.issue(TRIANGLE,1,5,V).ok)
        self.assertFalse(self.issue(PRESENT,2).ok)
        self.assertEqual(self.s.telemetry,[])
        self.assertEqual(self.s.gpu.present_commits,0)

    def test_invalid_opcode_error_result_not_telemetry(self):
        result=self.issue(INVALID,111)
        self.assertFalse(result.ok)
        self.assertEqual(result.tag,111)
        self.assertEqual(len(self.s.telemetry),0)

    def test_clear_present_frame_crc_matches_bytes(self):
        self.first(0xabcdef)
        self.assertEqual(len(self.s.drain()),16)
        record,=decode_host_frames(self.s.telemetry[0])
        self.assertEqual(record['sequence'],0)
        self.assertEqual(record['frame_crc'],crc([0xabcdef]*16))
        self.assertEqual((record['good'],record['bad'],record['aborted']),(1,0,0))

    def test_back_clear_does_not_tear_front(self):
        self.first(0x111111)
        self.assertTrue(self.issue(CLEAR,13,0x222222).ok)
        a=self.s.drain(ready=lambda t:t%3!=0)
        self.assertEqual([p.color for p in a],[0x111111]*16)
        self.assertTrue(self.issue(PRESENT,14).ok)
        b=self.s.drain()
        self.assertEqual([p.color for p in b],[0x222222]*16)
        self.assertEqual([f['frame_crc'] for f in decode_host_frames(b''.join(self.s.telemetry))],
                         [crc([0x111111]*16),crc([0x222222]*16)])

    def test_present_while_first_frame_stalled_waits_for_prior_eof(self):
        self.first(0xaaaaaa)
        self.issue(CLEAR,13,0xbbbbbb)
        # The software model's issue() pumps the prior frame to release swap.
        result=self.s.issue(wire(PRESENT,14),ready=lambda i:i%5==4)
        self.assertTrue(decode_result(result).ok)
        self.assertEqual(self.s.gpu.completed_frames,1)
        self.assertEqual(self.s.gpu.present_commits,2)
        self.assertEqual(len(self.s.telemetry),1)
        self.assertEqual(self.s.telemetry and decode_host_frames(self.s.telemetry[0])[0]['frame_crc'],
                         crc([0xaaaaaa]*16))
        self.assertEqual({p.color for p in self.s.drain()},{0xbbbbbb})

    def test_triangle_legacy_depth_always_overwrites(self):
        self.issue(CLEAR,1,0)
        self.issue(TRIANGLE,2,0xff0000,V)
        self.issue(TRIANGLE,3,0x00ff00,V)
        self.issue(PRESENT,4)
        colors=[p.color for p in self.s.drain()]
        for y in range(4):
            for x in range(4):
                self.assertEqual(colors[y*4+x],0x00ff00 if covered(((0,0),(4,0),(0,4)),x,y) else 0)

    def test_crc_rejects_corrupted_telemetry(self):
        self.first();self.s.drain()
        broken=bytearray(self.s.telemetry[0]);broken[8]^=8
        with self.assertRaises(ValueError):decode_host_frames(bytes(broken))

    def test_capture_can_interleave_only_at_frame_boundaries(self):
        self.first(0x123456);self.s.drain()
        order=['result','frame','result']
        stream=self.s.capture(order=order)
        self.assertEqual([r['kind'] for r in decode_host_frames(stream)],
                         ['result','frame','result'])
        self.assertEqual(len(stream),64)

    def test_capture_missing_or_unknown_lane_is_rejected(self):
        self.first();self.s.drain()
        for invalid in (['result','frame'],['result','result','frame','frame'],
                        ['result','result','oops']):
            with self.assertRaises(ValueError):self.s.capture(order=invalid)

    def test_random_host_byte_fragmentation(self):
        self.first(0x090807);self.s.drain()
        stream=self.s.capture(order=['result','frame','result'])
        for seed in range(12):
            r=random.Random(seed)
            dec=HostStreamDecoder();recs=[]
            off=0
            while off<len(stream):
                n=r.randrange(1,10)
                recs.extend(dec.feed(stream[off:off+n]));off+=n
            self.assertEqual(len(recs),3)
            self.assertEqual(dec.finish()['incomplete_tail_bytes'],0)

    def test_telemetry_sequence_and_good_counts_over_repeated_frames(self):
        for i in range(12):
            self.issue(CLEAR,2*i,i+1)
            self.issue(PRESENT,2*i+1)
            self.s.drain(ready=lambda t:(t+i)%4!=0)
        frames=decode_host_frames(b''.join(self.s.telemetry))
        self.assertEqual([f['sequence'] for f in frames],list(range(12)))
        self.assertEqual([f['good'] for f in frames],list(range(1,13)))
        self.assertTrue(all(f['bad']==0 for f in frames))

    def test_reset_discards_previous_capture_context(self):
        self.first();self.s.drain();self.s.reset()
        self.assertEqual((self.s.results,self.s.telemetry,self.s.tags),([],[],[]))
        self.assertFalse(self.issue(PRESENT,22).ok)
        self.assertEqual(self.s.sequence,0)

    def test_rtl_contract_connected_exactly_once(self):
        source=(Path(__file__).resolve().parents[1]/'rtl/graphics/a0_host_dual_bank_telemetry_bridge_p105.sv').read_text()
        for module in ('a0_host_command_rx_p45','a0_command_dual_bank_scanout_p104',
                       'a0_host_result_tx_p46','a0_scanout_frame_guard_p47',
                       'a0_scanout_telemetry_tx_p48','a0_host_tx_fair_arbiter_p49'):
            self.assertEqual(source.count(module+' '),1)
        self.assertIn('.stream_active(scan_active)',source)
        self.assertIn('.cmd_depth_op(2\'d0)',source)
        self.assertIn('.cmd_depth_write(1\'b0)',source)
        self.assertIn('.cmd_blend_enable(1\'b0)',source)

if __name__=='__main__':unittest.main()
