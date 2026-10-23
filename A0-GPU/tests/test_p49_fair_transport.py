"""P49 SOFTWARE reference tests, not a replacement for RTL simulation."""
import random
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from a0_fair_arbiter_p49 import FairArbiter
from a0_host_stream_p49 import HostStreamDecoder, FrameSequenceAudit
from a0_frame_telemetry_p48 import encode_frame, decode_host_frames, TelemetryTxSpec
from a0_host_result_wire_p46 import serialize_result


def tel(sequence=0,dropped=0,good=0):
    return encode_frame(sequence=sequence,error=False,frame_crc=0x12345678,
                        good=good,bad=0,aborted=0,dropped=dropped)


class FairnessTests(unittest.TestCase):
    def test_first_grant_result_on_tie(self):
        m=FairArbiter()
        self.assertFalse(m.tick(result_valid=True,telemetry_valid=True).valid)
        self.assertEqual(m.lane,'result')

    def test_alternates_complete_frames_under_sustained_traffic(self):
        m=FairArbiter(); result_index=0; tel_index=0
        actual=[]; grants=[]
        for _ in range(400):
            e=m.tick(result_valid=True,result_byte=0x40+result_index,
                     telemetry_valid=True,telemetry_byte=0x80+tel_index,
                     host_ready=True)
            if e.transferred:
                actual.append(e.byte)
                if e.lane=='result':result_index=(result_index+1)%16
                else: tel_index=(tel_index+1)%32
            if e.lane is None and m.lane is not None:
                grants.append(m.lane)
            if len(grants)==7 and m.lane is None:
                break
        self.assertEqual(grants[:7], ['result','telemetry','result','telemetry',
                                     'result','telemetry','result'])
        expected=(bytes(range(0x40,0x50))+bytes(range(0x80,0xa0)))*3 +bytes(range(0x40,0x50))
        self.assertEqual(bytes(actual),expected)

    def test_no_preemption_during_stall(self):
        m=FairArbiter();m.tick(telemetry_valid=True)
        for i in range(32):
            for _ in range(5):
                edge=m.tick(result_valid=True,result_byte=0xff,
                            telemetry_valid=True,telemetry_byte=i,host_ready=False)
                self.assertEqual((edge.lane,edge.byte,edge.transferred),('telemetry',i,False))
            edge=m.tick(result_valid=True,telemetry_valid=True,telemetry_byte=i,
                        host_ready=True)
            self.assertEqual(edge.byte,i)
        self.assertIsNone(m.lane)
        m.tick(result_valid=True,telemetry_valid=True)
        self.assertEqual(m.lane,'result')

    def test_solo_traffic_not_blocked_by_preference(self):
        m=FairArbiter();m.prefer_telemetry=True
        m.tick(result_valid=True)
        self.assertEqual(m.lane,'result')
        m.reset();m.prefer_telemetry=False
        m.tick(telemetry_valid=True)
        self.assertEqual(m.lane,'telemetry')

    def test_reset_discards_grant_and_restores_initial_priority(self):
        m=FairArbiter();m.tick(result_valid=True)
        for _ in range(8):m.tick(result_valid=True,host_ready=True)
        self.assertFalse(m.tick(rst_n=False,host_ready=True).valid)
        self.assertEqual((m.lane,m.index,m.prefer_telemetry),(None,0,False))
        m.tick(result_valid=True,telemetry_valid=True)
        self.assertEqual(m.lane,'result')

    def test_full_crc_frames_under_deterministic_random_stalls(self):
        rng=random.Random(49049);m=FairArbiter()
        rp=[serialize_result(i,False,i*100) for i in range(5)]
        tp=[tel(i,good=i) for i in range(5)]
        r_idx=t_idx=0;stream=bytearray()
        for cycle in range(6000):
            rv=r_idx<len(rp)*16;tv=t_idx<len(tp)*32
            e=m.tick(result_valid=rv,result_byte=rp[r_idx//16][r_idx%16] if rv else 0,
                     telemetry_valid=tv,telemetry_byte=tp[t_idx//32][t_idx%32] if tv else 0,
                     host_ready=bool(rng.randrange(4)))
            if e.transferred:
                stream.append(e.byte)
                if e.lane=='result':r_idx+=1
                else:t_idx+=1
            if r_idx==80 and t_idx==160:break
        else:self.fail('No forward progress in bounded stochastic test')
        records=decode_host_frames(bytes(stream))
        self.assertEqual([rec['kind'] for rec in records], ['result','frame']*5)
        self.assertEqual([rec['tag'] for rec in records if rec['kind']=='result'],list(range(5)))
        self.assertEqual([rec['sequence'] for rec in records if rec['kind']=='frame'],list(range(5)))
        self.assertEqual(len(stream),240)

    def test_old_arbiter_starves_telemetry_new_arbiter_does_not(self):
        from a0_frame_telemetry_p48 import FrameArbiterSpec
        old=FrameArbiterSpec();new=FairArbiter()
        def run(m,cycles):
            got=[]
            for _ in range(cycles):
                e=m.tick(result_valid=True,result_byte=0x55,
                         telemetry_valid=True,telemetry_byte=0xcc,host_ready=True)
                if (e.transferred if hasattr(e, 'transferred') else e.emitted):got.append(e.lane)
            return got
        self.assertNotIn('frame',run(old,160))
        self.assertIn('telemetry',run(new,160))


class HostDecoderTests(unittest.TestCase):
    def test_all_fragment_sizes_and_mixed_packets(self):
        wire=serialize_result(10,False,100)+tel(65535)+tel(0)+serialize_result(11,True,3)
        expected=decode_host_frames(wire)
        for chunk in range(1,37):
            d=HostStreamDecoder();found=[]
            for i in range(0,len(wire),chunk):found+=d.feed(wire[i:i+chunk])
            self.assertEqual(found,expected)
            self.assertEqual(d.finish()['incomplete_tail_bytes'],0)

    def test_recovers_corrupted_frame_and_untrusted_garbage(self):
        bad=bytearray(tel(2));bad[13]^=0x40
        good=[serialize_result(11,False,99),tel(5)]
        wire=b'\x00noiseA0' + good[0]+bytes(bad)+b'junk' + good[1]
        d=HostStreamDecoder();seen=[]
        for i in range(0,len(wire),5):seen+=d.feed(wire[i:i+5])
        self.assertEqual(seen,decode_host_frames(b''.join(good)))
        self.assertEqual(d.invalid_candidates,1)
        self.assertGreater(d.discarded_bytes,0)

    def test_reject_recomputed_crc_with_invalid_version_and_flags(self):
        import zlib
        for pos,value in [(4,2),(5,128)]:
            pkt=bytearray(tel(9));pkt[pos]=value
            pkt[-4:]=zlib.crc32(pkt[:-4]).to_bytes(4,'little')
            dec=HostStreamDecoder();self.assertEqual(dec.feed(pkt),[])
            self.assertEqual(dec.invalid_candidates,1)

    def test_no_output_from_truncated_frame(self):
        d=HostStreamDecoder();frame=tel(3)
        self.assertEqual(d.feed(frame[:-1]),[])
        self.assertTrue(d.finish()['truncated_packet'])
        self.assertEqual(d.feed(frame[-1:])[0]['sequence'],3)
        self.assertFalse(d.finish()['truncated_packet'])

    def test_capture_noise_buffer_bounded_and_observations_explicit(self):
        d=HostStreamDecoder()
        self.assertEqual(d.feed(b'Z'*100_000),[])
        self.assertLess(len(d.buffer),32)
        self.assertEqual(d.discarded_bytes,100_000)
        self.assertEqual(d.feed(tel(4))[0]['sequence'],4)
        self.assertEqual(d.decoded_packets,1)

    def test_embedded_magic_in_payload_not_an_extra_record(self):
        f=encode_frame(sequence=0,error=False,frame_crc=int.from_bytes(b'A0GF','little'),
                       good=0,bad=0,aborted=0,dropped=0)
        d=HostStreamDecoder()
        self.assertEqual(len(d.feed(f)),1)
        self.assertEqual(d.finish()['decoded_packets'],1)

    def test_sequence_wrap_and_drop_counter_audited_without_overclaiming(self):
        aud=FrameSequenceAudit()
        for seq,drop in [(65534,0),(65535,1),(1,3),(1,3),(2,0)]:
            aud.consume(decode_host_frames(tel(seq,dropped=drop))[0])
        r=aud.report()
        self.assertEqual(r['minimum_sequence_gaps_mod_65536'],1)
        self.assertEqual(r['same_sequence_ambiguous'],1)
        self.assertEqual(r['drop_count_regressions'],1)
        self.assertEqual(r['observed_drop_counter_increments'],3)
        self.assertTrue(r['sequence_wrap_ambiguity'])

    def test_nonbinary_rejected(self):
        with self.assertRaises(TypeError):HostStreamDecoder().feed('not bytes')

    def test_p48_telemetry_tx_integrates_with_incremental_decoder(self):
        tx=TelemetryTxSpec();tx.tick(frame_valid=True,frame_crc=0xbeef,good=1)
        wire=bytes(tx.tick(tx_ready=True).byte for _ in range(32))
        decoder=HostStreamDecoder()
        observed=[]
        for byte in wire:observed.extend(decoder.feed(bytes([byte])))
        self.assertEqual(observed[0]['frame_crc'],0xbeef)
        self.assertEqual(decoder.invalid_candidates,0)

class CaptureCliTests(unittest.TestCase):
    def test_cli_reads_valid_mixed_wire_and_writes_receipt(self):
        import tempfile,json
        from a0_host_trace_p49 import main
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'capture.bin';report=Path(td)/'report.json'
            src.write_bytes(serialize_result(17,False,42)+tel(7,dropped=0))
            self.assertEqual(main(['--capture',str(src),'--report',str(report),'--chunk-size','1']),0)
            doc=json.loads(report.read_text())
            self.assertEqual(doc['kind'],'A0_P49_CAPTURE_AUDIT_SOFTWARE_ONLY')
            self.assertEqual(doc['command_results'][0]['tag'],17)
            self.assertEqual(doc['sequence_audit']['telemetry_packets'],1)

    def test_cli_corrupt_fails_closed_unless_explicitly_allowed(self):
        import tempfile
        from a0_host_trace_p49 import main
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'capture.bin';report=Path(td)/'report.json'
            invalid=bytearray(tel(1)); invalid[12]^=1
            src.write_bytes(bytes(invalid)+tel(2))
            args=['--capture',str(src),'--report',str(report)]
            self.assertEqual(main(args),1)
            self.assertEqual(main(args+['--allow-corruption']),0)

    def test_cli_require_lossless_rejects_observable_sequence_gap(self):
        import tempfile
        from a0_host_trace_p49 import main
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'capture.bin';report=Path(td)/'report.json'
            src.write_bytes(tel(0)+tel(3,dropped=2))
            self.assertEqual(main(['--capture',str(src),'--report',str(report)]),0)
            self.assertEqual(main(['--capture',str(src),'--report',str(report),'--require-lossless']),1)

if __name__=="__main__": unittest.main()
