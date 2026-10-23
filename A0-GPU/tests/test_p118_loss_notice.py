"""P118 software reference and protocol contract tests; NOT RTL simulation."""
import random
import sys
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p118_loss_notice import *
from a0_frame_telemetry_p48 import encode_frame, decode_host_frames
from a0_host_protocol_p44 import encode_result, Result


def drain(model,steps=3000):
    out=bytearray()
    for _ in range(steps):
        e=model.tick(tx_ready=True)
        if e.emitted:out.append(e.byte)
        if not model.queue and not model.notice_owed:break
    return bytes(out)

class TestLossNotice(unittest.TestCase):
    def test_no_loss_wire_compatibility(self):
        m=LossTelemetryFifoSpec()
        for i in range(3):m.tick(frame_valid=True,frame_crc=100+i,good=i)
        got=drain(m)
        self.assertEqual(got,b''.join(encode_frame(sequence=i,error=False,frame_crc=100+i,
                      good=i,bad=0,aborted=0,dropped=0) for i in range(3)))
        self.assertEqual(audit_loss_notices(got,final_dropped=0)['notices'],0)
    def test_quiet_tail_overflow_report(self):
        m=LossTelemetryFifoSpec()
        for i in range(6):m.tick(frame_valid=True,frame_crc=100+i)
        self.assertEqual((len(m.queue),m.dropped,m.sequence,m.notice_owed),(4,2,6,True))
        raw=drain(m)
        rows=decode_p118_stream(raw)
        self.assertEqual([r['kind'] for r in rows],['frame']*4+['loss_notice'])
        self.assertEqual([r['sequence'] for r in rows],[0,1,2,3,6])
        self.assertEqual((rows[-1]['dropped'],rows[-1]['good']),(2,0))
        self.assertEqual(audit_loss_notices(raw,final_dropped=2)['notices'],1)
        with self.assertRaises(ValueError):decode_host_frames(raw)
    def test_loss_notice_prioritized_on_free_slot(self):
        m=LossTelemetryFifoSpec()
        for i in range(4):m.tick(frame_valid=True,frame_crc=i)
        self.assertTrue(m.tick(frame_valid=True).dropped)
        for _ in range(31):m.tick(tx_ready=True)
        edge=m.tick(tx_ready=True,frame_valid=True)
        self.assertTrue(edge.notice_enqueued)
        self.assertFalse(edge.frame_accepted)
        self.assertTrue(edge.dropped)
        self.assertEqual((m.dropped,m.sequence,m.notice_owed),(2,6,True))
        raw=drain(m)
        # The first byte-packet was drained prior to the edge; parse remaining.
        rows=decode_p118_stream(raw)
        self.assertEqual([r['kind'] for r in rows],['frame']*3+['loss_notice']+['loss_notice'])
        self.assertEqual([r['dropped'] for r in rows if r['kind']=='loss_notice'],[1,2])
    def test_multiple_quiet_bursts(self):
        m=LossTelemetryFifoSpec(depth=2)
        for _ in range(4):m.tick(frame_valid=True)
        x=drain(m)
        self.assertEqual(audit_loss_notices(x,final_dropped=2)['notices'],1)
        for _ in range(5):m.tick(frame_valid=True)
        y=drain(m)
        self.assertEqual(audit_loss_notices(x+y,final_dropped=5)['notices'],2)
    def test_reset_fails_to_claim_delivered_notice(self):
        m=LossTelemetryFifoSpec()
        for _ in range(5):m.tick(frame_valid=True)
        self.assertTrue(m.notice_owed)
        m.tick(rst_n=False)
        self.assertFalse(m.notice_owed)
        self.assertEqual((m.dropped,m.sequence,len(m.queue)),(0,0,0))
        self.assertFalse(m.tick(tx_ready=True).valid)
    def test_sequence_wrap(self):
        m=LossTelemetryFifoSpec()
        m.sequence=65534
        for _ in range(5):m.tick(frame_valid=True)
        a=decode_p118_stream(drain(m))
        self.assertEqual([x['sequence'] for x in a],[65534,65535,0,1,3])
    def test_drop_saturation(self):
        m=LossTelemetryFifoSpec();m.dropped=0xffffffff
        for _ in range(5):m.tick(frame_valid=True)
        a=decode_p118_stream(drain(m))
        self.assertEqual(a[-1]['dropped'],0xffffffff)
    def test_non_power_of_two_depth(self):
        m=LossTelemetryFifoSpec(3)
        for i in range(13):m.tick(frame_valid=True,frame_crc=i)
        rows=decode_p118_stream(drain(m))
        self.assertEqual(len(rows),4)
        self.assertEqual(rows[-1]['dropped'],10)
    def test_no_bad_depth(self):
        for d in (-1,0,1,True,2.3):
            with self.assertRaises(ValueError):LossTelemetryFifoSpec(d)
    def test_packet_snapshot_immutable_under_stalls(self):
        m=LossTelemetryFifoSpec()
        m.tick(frame_valid=True,frame_crc=444)
        before=m.queue[0]
        for _ in range(8):m.tick(tx_ready=False,frame_valid=True)
        self.assertEqual(m.queue[0],before)
        self.assertGreaterEqual(m.dropped,1)
        r=decode_p118_stream(drain(m))
        self.assertEqual(r[0]['frame_crc'],444)
        self.assertEqual(r[-1]['kind'],'loss_notice')
    def test_strict_decoder_mixed_result(self):
        loss=encode_loss_notice(sequence=12,dropped=5,good=4,bad=3,aborted=2)
        result=encode_result(Result(0,9,12))
        rows=decode_p118_stream(result+loss)
        self.assertEqual((rows[0]['kind'],rows[1]['kind']),('result','loss_notice'))
        self.assertEqual(rows[1]['aborted'],2)
    def test_packet_errors_fail_closed(self):
        good=encode_loss_notice(sequence=7,dropped=4,good=2,bad=0,aborted=0)
        for off in range(32):
            damaged=bytearray(good);damaged[off]^=1
            with self.assertRaises(ValueError):decode_p118_stream(bytes(damaged))
        for chunk in (b'',b'A0G',good[:-1],b'junk'+good,good+b'x'):
            if not chunk: self.assertEqual(decode_p118_stream(chunk),[])
            else:
                with self.assertRaises(ValueError):decode_p118_stream(chunk)
    def test_semantic_notice_rejections(self):
        good=bytearray(encode_loss_notice(sequence=0,dropped=1,good=0,bad=0,aborted=0))
        import zlib
        for index,value in [(4,2),(5,0),(8,0),(24,1)]:
            b=bytearray(good);b[index]=value;b[28:]=zlib.crc32(b[:28]).to_bytes(4,'little')
            with self.assertRaises(ValueError):decode_p118_stream(bytes(b))
    def test_bad_encoder_input(self):
        for field,value in [('sequence',-1),('sequence',65536),('sequence',True),('dropped',0),('dropped',-1),('good',1.3)]:
            kw=dict(sequence=1,dropped=1,good=0,bad=0,aborted=0);kw[field]=value
            with self.assertRaises(ValueError):encode_loss_notice(**kw)
    def test_monotone_counter_audit(self):
        n1=encode_loss_notice(sequence=3,dropped=5,good=0,bad=0,aborted=0)
        n2=encode_loss_notice(sequence=4,dropped=4,good=0,bad=0,aborted=0)
        with self.assertRaises(ValueError):audit_loss_notices(n1+n2)
        with self.assertRaises(ValueError):audit_loss_notices(n1,final_dropped=6)
        with self.assertRaises(ValueError):audit_loss_notices(n1,final_dropped=-1)
        with self.assertRaises(ValueError):audit_loss_notices(encode_frame(sequence=0,error=False,frame_crc=0,good=0,bad=0,aborted=0,dropped=1),final_dropped=1)
    def test_randomized_queue_and_notice_integrity(self):
        rng=random.Random(118005)
        for depth in (2,3,4,7):
            m=LossTelemetryFifoSpec(depth);wire=bytearray();events=0
            for i in range(3000):
                frame=rng.randrange(6)==0
                edge=m.tick(frame_valid=frame,frame_crc=i,good=i,tx_ready=rng.choice([True,False]))
                if edge.emitted:wire.append(edge.byte)
                events+=bool(frame)
            wire+=drain(m,8000)
            rows=decode_p118_stream(bytes(wire))
            self.assertEqual(len(wire)%32,0)
            frames=[r for r in rows if r['kind']=='frame']
            self.assertEqual(len(frames)+m.dropped,events)
            self.assertEqual(audit_loss_notices(bytes(wire),final_dropped=m.dropped)['last_witnessed_drops'],m.dropped)
    def test_static_rtl_loss_priority(self):
        rtl=(ROOT/'rtl/graphics/a0_scanout_telemetry_loss_fifo_p118.sv').read_text()
        for token in ('notice_owed_q && free_slot','frame_valid && free_slot && !notice_owed_q',
                      "overflow_event) notice_owed_q<=1'b1","push_notice) notice_owed_q<=1'b0",
                      "32'h4c473041",'finish_packet','crc32_28(notice_payload)'):
            self.assertIn(token,rtl)
    def test_bridge_keeps_p117_pipeline(self):
        a=(ROOT/'rtl/graphics/a0_host_fragment_dual_bank_bridge_p117.sv').read_text()
        b=(ROOT/'rtl/graphics/a0_host_fragment_dual_bank_bridge_p118.sv').read_text()
        for mod in ('a0_host_command_rx_p106','a0_command_dual_bank_scanout_p104','a0_scanout_frame_guard_p47','a0_host_tx_fair_arbiter_p49','a0_host_result_tx_p46'):
            self.assertEqual(a.count(mod+' '),1);self.assertEqual(b.count(mod+' '),1)
        self.assertIn('a0_scanout_telemetry_loss_fifo_p118',b)
        self.assertIn('loss_notice_pending(telemetry_loss_notice_pending)',b)

if __name__=='__main__':unittest.main()
