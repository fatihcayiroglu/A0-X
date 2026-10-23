"""P117 FIFO software and static RTL integration tests (not HDL simulation)."""
import random
import sys
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
from a0_p117_telemetry_fifo import TelemetryFifoSpec
from a0_frame_telemetry_p48 import decode_host_frames


class P117FifoTests(unittest.TestCase):
    def test_empty_and_reset(self):
        m = TelemetryFifoSpec()
        self.assertFalse(m.tick(tx_ready=True).valid)
        m.tick(frame_valid=True, frame_crc=0x22)
        self.assertEqual(len(m.queue), 1)
        m.tick(tx_ready=True)
        self.assertEqual((m.offset,len(m.queue)),(1,1))
        m.tick(rst_n=False)
        self.assertEqual((m.offset,len(m.queue),m.sequence,m.dropped),(0,0,0,0))

    def test_invalid_depth(self):
        for depth in (0, 1, -3, True, 2.5):
            with self.assertRaises(ValueError): TelemetryFifoSpec(depth)
        self.assertEqual(TelemetryFifoSpec(depth=3).depth,3)

    def test_four_frames_no_loss_during_stall(self):
        m = TelemetryFifoSpec()
        for i in range(4):
            self.assertTrue(m.tick(frame_valid=True,frame_crc=i+10,good=i+1).accepted)
        self.assertEqual(len(m.queue),4)
        for _ in range(100):
            e=m.tick(tx_ready=False)
            self.assertEqual(e.byte,ord('A'))
            self.assertFalse(e.emitted)
        wire=bytearray()
        for _ in range(128):
            e=m.tick(tx_ready=True)
            self.assertTrue(e.emitted)
            wire.append(e.byte)
        rows=decode_host_frames(bytes(wire))
        self.assertEqual([r['sequence'] for r in rows],[0,1,2,3])
        self.assertEqual([r['frame_crc'] for r in rows],[10,11,12,13])
        self.assertTrue(all(r['dropped']==0 for r in rows))
        self.assertEqual(len(m.queue),0)

    def test_full_drop_sequence_and_snapshot(self):
        m=TelemetryFifoSpec()
        for i in range(6): m.tick(frame_valid=True,frame_crc=i)
        self.assertEqual((len(m.queue),m.dropped,m.sequence),(4,2,6))
        for _ in range(32): m.tick(tx_ready=True)
        m.tick(frame_valid=True,frame_crc=99)
        # Dropped count reflects events dropped before this accepted event.
        last=decode_host_frames(m.queue[-1])[0]
        self.assertEqual((last['sequence'],last['dropped'],last['frame_crc']), (6,2,99))

    def test_full_last_byte_simultaneous_enqueue(self):
        m=TelemetryFifoSpec()
        for i in range(4): m.tick(frame_valid=True,frame_crc=100+i)
        for i in range(31): m.tick(tx_ready=True)
        e=m.tick(frame_valid=True,frame_crc=300,tx_ready=True)
        self.assertTrue(e.accepted)
        self.assertTrue(e.emitted)
        self.assertFalse(e.dropped)
        self.assertEqual(len(m.queue),4)
        self.assertEqual(m.offset,0)
        self.assertEqual([decode_host_frames(x)[0]['sequence'] for x in m.queue],[1,2,3,4])
        self.assertEqual(m.dropped,0)

    def test_full_midpacket_new_event_is_dropped(self):
        m=TelemetryFifoSpec()
        for i in range(4): m.tick(frame_valid=True)
        for i in range(30):m.tick(tx_ready=True)
        e=m.tick(frame_valid=True,tx_ready=True)
        self.assertFalse(e.accepted)
        self.assertTrue(e.dropped)
        self.assertEqual(m.dropped,1)

    def test_exact_packet_fields_immutable(self):
        m=TelemetryFifoSpec()
        m.tick(frame_valid=True,error=True,frame_crc=0xdeadbeef,good=10,bad=3,aborted=2)
        before=bytes(m.queue[0]); out=bytearray()
        for idx in range(32):
            m.tick(frame_valid=True,frame_crc=idx)
            for _ in range(5):
                e=m.tick(tx_ready=False)
                self.assertEqual(e.byte,before[idx])
            out.append(m.tick(tx_ready=True).byte)
        self.assertEqual(bytes(out),before)
        row=decode_host_frames(bytes(out))[0]
        self.assertEqual((row['error'],row['frame_crc'],row['good'],row['bad'],row['aborted']),
                         (True,0xdeadbeef,10,3,2))

    def test_sequence_wraparound_and_drop_saturation(self):
        m=TelemetryFifoSpec()
        m.sequence=65535;m.dropped=0xffffffff
        for _ in range(5):m.tick(frame_valid=True)
        self.assertEqual((m.sequence,m.dropped),(4,0xffffffff))
        self.assertEqual(decode_host_frames(m.queue[0])[0]['sequence'],65535)
        self.assertEqual(decode_host_frames(m.queue[1])[0]['sequence'],0)

    def test_fifo_depth_three_wraparound(self):
        m=TelemetryFifoSpec(3)
        for round_id in range(15):
            for i in range(3):
                self.assertTrue(m.tick(frame_valid=True,frame_crc=round_id*3+i).accepted)
            for i in range(96):m.tick(tx_ready=True)
            self.assertEqual(len(m.queue),0)
        self.assertEqual((m.dropped,m.sequence),(0,45))

    def test_random_stalls_fifo_order_and_overflow(self):
        rng=random.Random(1172026)
        m=TelemetryFifoSpec()
        expected=[]
        wire=bytearray()
        for t in range(2500):
            incoming=(rng.randrange(15)==0)
            before=len(m.queue)
            pop=bool(m.queue and m.offset==31)
            frame_crc=rng.getrandbits(32)
            e=m.tick(frame_valid=incoming,frame_crc=frame_crc,good=t,
                     tx_ready=bool(rng.getrandbits(1)))
            if e.emitted:wire.append(e.byte)
            if e.accepted:expected.append((m.sequence-1 & 0xffff,frame_crc))
            if e.dropped:self.assertTrue(incoming and before==4)
        for _ in range(1000):
            e=m.tick(tx_ready=True)
            if e.emitted:wire.append(e.byte)
            if not m.queue:break
        self.assertEqual(len(wire)%32,0)
        got=decode_host_frames(bytes(wire))
        self.assertEqual([(r['sequence'],r['frame_crc']) for r in got],expected)

    def test_rtl_source_has_fifo_correct_handoff(self):
        s=(ROOT/'rtl/graphics/a0_scanout_telemetry_fifo_p117.sv').read_text()
        for snippet in ('finish_packet','push_packet','overflow_event',
                        'count_q < COUNT_BITS\'(FIFO_DEPTH)',
                        'frame_valid && ((count_q', 'case ({push_packet,finish_packet})',
                        'crc32_28(payload)', 'packets[rd_q]'):
            self.assertIn(snippet,s)

    def test_p117_bridge_replaces_sender_preserves_older_blocks(self):
        p=(ROOT/'rtl/graphics/a0_host_fragment_dual_bank_bridge_p117.sv').read_text()
        original=(ROOT/'rtl/graphics/a0_host_fragment_dual_bank_bridge_p106.sv').read_text()
        self.assertIn('a0_scanout_telemetry_fifo_p117 #(',p)
        self.assertNotIn('a0_scanout_telemetry_tx_p48 telemetry_sender',p)
        for mod in ('a0_host_command_rx_p106','a0_command_dual_bank_scanout_p104',
                    'a0_host_result_tx_p46','a0_scanout_frame_guard_p47',
                    'a0_host_tx_fair_arbiter_p49'):
            self.assertIn(mod+' ',p)
            self.assertIn(mod+' ',original)
        self.assertIn('.queued_frame_events(telemetry_queued_frames)',p)


if __name__=='__main__': unittest.main()
