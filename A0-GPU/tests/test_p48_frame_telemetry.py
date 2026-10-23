"""Behavioral P48 reference unit tests. These DO NOT execute SystemVerilog."""
import random
import struct
import sys
import unittest
import zlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_frame_telemetry_p48 import (encode_frame, decode_host_frames,
                                    TelemetryTxSpec, FrameArbiterSpec)
from a0_host_result_wire_p46 import serialize_result

class P48TelemetryTests(unittest.TestCase):
    def packet(self, seq=0, error=False, crc=0x12345678, good=2,bad=0,aborted=3,dropped=0):
        return encode_frame(sequence=seq,error=error,frame_crc=crc,good=good,bad=bad,aborted=aborted,dropped=dropped)

    def test_exact_layout(self):
        packet = self.packet(seq=0x1234,error=True,crc=0x87654321,good=5,bad=6,aborted=7,dropped=8)
        self.assertEqual(len(packet),32)
        self.assertEqual(packet[:8], b'A0GF\x01\x01\x34\x12')
        self.assertEqual(packet[8:12],b'\x21\x43\x65\x87')
        self.assertEqual(struct.unpack('<IIIII',packet[8:28]),(0x87654321,5,6,7,8))
        self.assertEqual(zlib.crc32(packet[:28]), int.from_bytes(packet[28:],'little'))

    def test_field_validation(self):
        for kwargs in [{'sequence':-1},{'sequence':65536},{'error':3},{'frame_crc':-1},
                       {'dropped':0x100000000},{'good':True}]:
            data = dict(sequence=0,error=False,frame_crc=0,good=0,bad=0,aborted=0,dropped=0)
            data.update(kwargs)
            with self.assertRaises(ValueError): encode_frame(**data)

    def test_result_compatibility_in_mixed_stream(self):
        wire = serialize_result(5,True,3) + self.packet(seq=42) + serialize_result(9,False,111)
        decoded = decode_host_frames(wire)
        self.assertEqual([x['kind'] for x in decoded],['result','frame','result'])
        self.assertEqual(decoded[0]['tag'],5)
        self.assertEqual(decoded[1]['sequence'],42)
        self.assertEqual(decoded[2]['cycles'],111)

    def test_corruption_and_truncation_fail_closed(self):
        good=self.packet()
        for i in range(32):
            wire=bytearray(good);wire[i]^=1
            with self.assertRaises(ValueError): decode_host_frames(bytes(wire))
        for i in range(1,32):
            with self.assertRaises(ValueError): decode_host_frames(good[:i])
        with self.assertRaises(ValueError): decode_host_frames(b'ABCD')

    def test_random_packets_roundtrip(self):
        rng=random.Random(48001)
        for _ in range(300):
            values=dict(sequence=rng.randrange(65536),error=bool(rng.getrandbits(1)),
                        frame_crc=rng.getrandbits(32), good=rng.getrandbits(32),
                        bad=rng.getrandbits(32),aborted=rng.getrandbits(32),
                        dropped=rng.getrandbits(32))
            p=encode_frame(**values)
            got=decode_host_frames(p)[0]
            self.assertEqual(got['frame_crc'],values['frame_crc'])
            self.assertEqual(got['dropped'],values['dropped'])
            self.assertEqual(got['error'],values['error'])
            self.assertEqual(got['sequence'],values['sequence'])

    def test_tx_stalls_preserve_byte_and_crc(self):
        tx=TelemetryTxSpec()
        self.assertTrue(tx.tick(frame_valid=True,good=1,frame_crc=0x1234).accepted)
        sent=bytearray()
        for index in range(32):
            for _ in range(5):
                e=tx.tick(tx_ready=False)
                self.assertTrue(e.valid)
                self.assertEqual(e.byte,self.packet(seq=0,good=1,crc=0x1234,aborted=0)[index])
            e=tx.tick(tx_ready=True)
            self.assertTrue(e.emitted)
            sent.append(e.byte)
        self.assertEqual(bytes(sent),self.packet(seq=0,good=1,crc=0x1234,aborted=0))
        self.assertFalse(tx.tick().valid)

    def test_drop_and_sequence_gap(self):
        tx=TelemetryTxSpec()
        tx.tick(frame_valid=True,frame_crc=111)
        for _ in range(5): tx.tick(frame_valid=True)
        self.assertEqual(tx.dropped,5)
        for _ in range(32): tx.tick(tx_ready=True)
        self.assertTrue(tx.tick(frame_valid=True,good=7,frame_crc=222).accepted)
        actual=bytes(tx.tick(tx_ready=True).byte for _ in range(32))
        d=decode_host_frames(actual)[0]
        self.assertEqual((d['sequence'],d['dropped'],d['good'],d['frame_crc']),(6,5,7,222))

    def test_drop_counter_saturates_sequence_wraps(self):
        tx=TelemetryTxSpec()
        tx.sequence=65535
        tx.dropped=0xffffffff
        tx.tick(frame_valid=True)
        tx.tick(frame_valid=True)
        self.assertEqual(tx.dropped,0xffffffff)
        self.assertEqual(tx.sequence,1)

    def test_reset_discards_partial_telemetry(self):
        tx=TelemetryTxSpec()
        tx.tick(frame_valid=True)
        tx.tick(tx_ready=True)
        tx.tick(tx_ready=True)
        self.assertFalse(tx.tick(rst_n=False).valid)
        self.assertEqual((tx.sequence,tx.dropped,tx.index),(0,0,0))
        self.assertTrue(tx.tick(frame_valid=True).accepted)

    def test_registered_arbiter_gives_results_priority(self):
        arb=FrameArbiterSpec()
        e=arb.tick(result_valid=True,telemetry_valid=True,host_ready=True)
        self.assertFalse(e.valid)
        self.assertEqual(arb.lane,'result')
        e=arb.tick(result_valid=True,result_byte=1,telemetry_valid=True,telemetry_byte=2,host_ready=True)
        self.assertEqual((e.byte,e.result_ready,e.telemetry_ready),(1,True,False))

    def test_arbiter_no_interleave_stalled_telemetry(self):
        arb=FrameArbiterSpec()
        arb.tick(telemetry_valid=True)
        for i in range(32):
            e=arb.tick(telemetry_valid=True,telemetry_byte=i,
                       result_valid=True,result_byte=255,host_ready=False)
            self.assertEqual(e.byte,i)
            self.assertFalse(e.telemetry_ready)
            e=arb.tick(telemetry_valid=True,telemetry_byte=i,
                       result_valid=True,result_byte=255,host_ready=True)
            self.assertEqual(e.byte,i)
            self.assertTrue(e.telemetry_ready)
            self.assertFalse(e.result_ready)
        self.assertIsNone(arb.lane)
        arb.tick(result_valid=True)
        self.assertEqual(arb.lane,'result')

    def test_arbiter_full_variable_length_packets(self):
        r=serialize_result(7,False,100)
        t=self.packet(seq=1,good=2)
        arb=FrameArbiterSpec()
        arb.tick(result_valid=True,telemetry_valid=True)
        wire=bytearray()
        for i in range(16):
            e=arb.tick(result_valid=True,result_byte=r[i],telemetry_valid=True,
                       telemetry_byte=t[0],host_ready=True)
            wire.append(e.byte)
        arb.tick(telemetry_valid=True)
        for i in range(32):
            e=arb.tick(telemetry_valid=True,telemetry_byte=t[i],host_ready=True)
            wire.append(e.byte)
        self.assertEqual(bytes(wire), r+t)
        self.assertEqual([x['kind'] for x in decode_host_frames(bytes(wire))],['result','frame'])

    def test_arbiter_reset_mid_frame(self):
        arb=FrameArbiterSpec()
        arb.tick(result_valid=True)
        arb.tick(result_valid=True,result_byte=65,host_ready=True)
        self.assertFalse(arb.tick(rst_n=False).valid)
        self.assertIsNone(arb.lane)
        arb.tick(telemetry_valid=True)
        self.assertEqual(arb.lane,'frame')

    def test_end_to_end_tick_random_stalls(self):
        rng=random.Random(48125)
        tx=TelemetryTxSpec()
        arb=FrameArbiterSpec()
        tx.tick(frame_valid=True,good=1,frame_crc=0xabc)
        # Model connected transmitter + arbiter with pre-edge signals.
        byte_stream=bytearray()
        for _ in range(600):
            telvalid=tx.packet is not None
            telbyte=tx.packet[tx.index] if telvalid else 0
            edge=arb.tick(telemetry_valid=telvalid,telemetry_byte=telbyte,
                          host_ready=bool(rng.getrandbits(1)))
            tx.tick(tx_ready=edge.telemetry_ready)
            if edge.emitted:
                byte_stream.append(edge.byte)
            if len(byte_stream)==32: break
        self.assertEqual(decode_host_frames(bytes(byte_stream))[0]['frame_crc'],0xabc)
        self.assertEqual(tx.index,0)

if __name__=='__main__': unittest.main()
