"""P119 host-capture epoch accounting. Everything is software-only."""
import contextlib
import io
import json
import random
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
sys.path.insert(0, str(ROOT / 'tools'))
from a0_frame_telemetry_p48 import encode_frame
from a0_host_protocol_p44 import Result, encode_result
from a0_p118_loss_notice import (LossTelemetryFifoSpec, encode_loss_notice,
                                 decode_p118_stream)
from a0_p119_epoch_reconcile import EpochReconciler, audit_epoch
from a0_p119_epoch_audit import main


def build(events=8, depth=4, ready_schedule=None):
    model = LossTelemetryFifoSpec(depth)
    raw = bytearray()
    for i in range(events):
        edge = model.tick(frame_valid=True, frame_crc=i, good=i, tx_ready=False)
        if edge.emitted:
            raw.append(edge.byte)
    for tick in range(20000):
        ready = True if ready_schedule is None else ready_schedule(tick)
        edge = model.tick(tx_ready=ready, good=events)
        if edge.emitted:
            raw.append(edge.byte)
        if not model.queue and not model.notice_owed:
            break
    else:
        raise AssertionError('fixture failed to drain')
    return bytes(raw), model.dropped


def recalc(blob):
    packet = bytearray(blob)
    packet[-4:] = zlib.crc32(packet[:-4]).to_bytes(4,'little')
    return bytes(packet)


class TestP119Epoch(unittest.TestCase):
    def test_no_frame_empty_epoch(self):
        self.assertEqual(audit_epoch(b'', epoch='boot-a', final_attempted=0,
                                     final_dropped=0)['packet_count'], 0)

    def test_loss_free_frames(self):
        raw, drops = build(4)
        self.assertEqual(drops, 0)
        report = audit_epoch(raw, epoch='session-0', final_attempted=4, final_dropped=0)
        self.assertEqual(report['accepted_frame_packets'], 4)
        self.assertFalse(report['physical_hardware_verified'])
        self.assertFalse(report['reset_proven'])
        self.assertFalse(report['final_counters_externally_authenticated'])

    def test_quiet_tail_overflow(self):
        raw, drops = build(9)
        r = audit_epoch(raw, epoch='s', final_attempted=9, final_dropped=drops)
        self.assertEqual((r['accepted_frame_packets'], r['final_dropped'], r['loss_notices']),
                         (4, 5, 1))

    def test_result_packets_interleave(self):
        raw, drops = build(3)
        r1 = encode_result(Result(0, 110, 1))
        r2 = encode_result(Result(0, 111, 2))
        mixed = raw[:32] + r1 + raw[32:] + r2
        result = audit_epoch(mixed, epoch='s', final_attempted=3, final_dropped=drops,
                             expected_result_tags=[110,111])
        self.assertEqual(result['result_packets'], 2)

    def test_out_of_order_result_tags_rejected_when_bounded(self):
        a = encode_result(Result(0, 1, 1)) + encode_result(Result(0, 2, 2))
        with self.assertRaisesRegex(ValueError, 'result mismatch'):
            audit_epoch(a, epoch='s', final_attempted=0, final_dropped=0,
                        expected_result_tags=[2,1])

    def test_error_result_rejected_when_tags_required(self):
        a = encode_result(Result(1, 1, 1))
        with self.assertRaisesRegex(ValueError, 'error result'):
            audit_epoch(a, epoch='s', final_attempted=0, final_dropped=0,
                        expected_result_tags=[1])
        self.assertEqual(audit_epoch(a, epoch='s', final_attempted=0,
                                     final_dropped=0)['result_error_packets'], 1)

    def test_packet_crc_rejected_and_poisoned(self):
        raw, d = build(4)
        b = bytearray(raw); b[7] ^= 1
        audit = EpochReconciler('a')
        with self.assertRaisesRegex(ValueError, 'crc'):
            audit.feed(bytes(b))
        with self.assertRaisesRegex(ValueError, 'invalidated'):
            audit.feed(raw)

    def test_missing_middle_frame_rejected(self):
        raw, d = build(4)
        with self.assertRaisesRegex(ValueError, 'discontinuity'):
            audit_epoch(raw[:32] + raw[64:],epoch='s',final_attempted=4,final_dropped=d)

    def test_replayed_frame_rejected(self):
        raw, d = build(4)
        with self.assertRaisesRegex(ValueError, 'discontinuity'):
            audit_epoch(raw[:32] + raw, epoch='s', final_attempted=5, final_dropped=d)

    def test_reordered_frames_rejected(self):
        raw, d = build(4)
        with self.assertRaisesRegex(ValueError, 'discontinuity'):
            audit_epoch(raw[32:64]+raw[:32]+raw[64:],epoch='s',final_attempted=4,final_dropped=d)

    def test_undelivered_last_frame_caught_by_external_boundary(self):
        raw, d = build(3)
        with self.assertRaisesRegex(ValueError, 'reconciliation'):
            audit_epoch(raw[:-32],epoch='s',final_attempted=3,final_dropped=d)

    def test_missing_tail_notice_detected(self):
        raw, d = build(9)
        self.assertEqual(decode_p118_stream(raw)[-1]['kind'], 'loss_notice')
        with self.assertRaisesRegex(ValueError, 'not witnessed|missing terminal'):
            audit_epoch(raw[:-32],epoch='s',final_attempted=9,final_dropped=d)

    def test_duplicate_notice_rejected(self):
        raw, d = build(9)
        with self.assertRaisesRegex(ValueError, 'stale loss notice|discontinuity'):
            audit_epoch(raw+raw[-32:],epoch='s',final_attempted=9,final_dropped=d)

    def test_fake_notice_counter_rejected_even_with_valid_crc(self):
        raw, d = build(9)
        b = bytearray(raw[-32:]); b[8:12]=(d+1).to_bytes(4,'little')
        with self.assertRaisesRegex(ValueError, 'discontinuity'):
            audit_epoch(raw[:-32]+recalc(b),epoch='s',final_attempted=9,final_dropped=d+1)

    def test_fake_frame_sequence_rejected_with_valid_crc(self):
        raw, d = build(3)
        b=bytearray(raw[:32]); b[6]=15
        with self.assertRaisesRegex(ValueError, 'discontinuity'):
            audit_epoch(recalc(b)+raw[32:],epoch='s',final_attempted=3,final_dropped=d)

    def test_counters_cannot_regress(self):
        raw, d = build(3)
        b=bytearray(raw[64:96]); b[12:16]=(0).to_bytes(4,'little')
        with self.assertRaisesRegex(ValueError, 'counter regressed'):
            audit_epoch(raw[:64]+recalc(b),epoch='s',final_attempted=3,final_dropped=d)

    def test_sequence_wrap_large_epoch(self):
        # A0GF is 16-bit. Epoch-bound attempt counts prevent modulo wrap from
        # hiding 65536 missing attempts, while short wire segments still wrap.
        accepted = 0
        raw = bytearray()
        for i in range(65538):
            raw += encode_frame(sequence=i&65535,error=False,frame_crc=i,
                                good=0,bad=0,aborted=0,dropped=0)
            accepted += 1
        r=audit_epoch(bytes(raw),epoch='wrap',final_attempted=accepted,final_dropped=0)
        self.assertEqual(r['accepted_frame_packets'],65538)
        with self.assertRaisesRegex(ValueError,'reconciliation'):
            audit_epoch(bytes(raw),epoch='wrap',final_attempted=accepted+65536,final_dropped=0)

    def test_saturated_drop_boundary_rejected(self):
        with self.assertRaisesRegex(ValueError, 'range'):
            audit_epoch(b'',epoch='s',final_attempted=0,final_dropped=0xffffffff)

    def test_strict_final_types(self):
        for x in (-1,True,1.25, '1'):
            with self.assertRaises(ValueError):
                audit_epoch(b'',epoch='s',final_attempted=x,final_dropped=0)
            with self.assertRaises(ValueError):
                audit_epoch(b'',epoch='s',final_attempted=0,final_dropped=x)

    def test_unbounded_or_bad_epoch_rejected(self):
        for x in ('', '  ', 99, None, 'x'*129):
            with self.assertRaises(ValueError):EpochReconciler(x)

    def test_partial_packet_fail_closed_at_finalize(self):
        raw, d=build(4)
        m=EpochReconciler('s');m.feed(raw[:-1])
        with self.assertRaisesRegex(ValueError,'truncated'):
            m.finalize(final_attempted=4,final_dropped=0)

    def test_random_byte_chunk_boundaries(self):
        raw,d=build(9)
        standard=audit_epoch(raw,epoch='s',final_attempted=9,final_dropped=d)
        for seed in range(16):
            rng=random.Random(seed)
            m=EpochReconciler('s');i=0
            while i<len(raw):
                n=rng.randint(1,35)
                m.feed(raw[i:i+n]);i+=n
            got=m.finalize(final_attempted=9,final_dropped=d)
            self.assertEqual(got,standard)

    def test_feed_requires_bytes_and_poisoned(self):
        m=EpochReconciler('s')
        with self.assertRaisesRegex(ValueError,'bytes'):m.feed(bytearray(b'X'))
        with self.assertRaisesRegex(ValueError,'invalidated'):m.feed(b'')

    def test_success_is_terminal(self):
        m=EpochReconciler('s');m.feed(b'')
        m.finalize(final_attempted=0,final_dropped=0)
        with self.assertRaisesRegex(ValueError,'closed'):m.feed(b'')
        with self.assertRaisesRegex(ValueError,'closed'):
            m.finalize(final_attempted=0,final_dropped=0)

    def test_unknown_packet_rejected(self):
        with self.assertRaisesRegex(ValueError,'magic'):
            audit_epoch(b'WRNG',epoch='s',final_attempted=0,final_dropped=0)

    def test_randomized_fifo_accounting(self):
        rng=random.Random(1192026)
        for depth in (2,3,4,5,7):
            for trial in range(8):
                m=LossTelemetryFifoSpec(depth=depth);raw=bytearray();attempted=0
                for i in range(1200):
                    present=rng.randrange(4)==0
                    e=m.tick(frame_valid=present,frame_crc=i,good=i,tx_ready=rng.randrange(2)==0)
                    attempted+=int(present)
                    if e.emitted:raw.append(e.byte)
                for i in range(5000):
                    e=m.tick(tx_ready=True,good=1200)
                    if e.emitted:raw.append(e.byte)
                    if not m.queue and not m.notice_owed:break
                got=audit_epoch(bytes(raw),epoch=f'r-{depth}-{trial}',
                                final_attempted=attempted, final_dropped=m.dropped)
                self.assertEqual(got['accepted_frame_packets']+m.dropped,attempted)

    def test_example_p118_fixture(self):
        raw=(ROOT/'examples/p118/software_only_tail_loss.bin').read_bytes()
        rows=decode_p118_stream(raw)
        self.assertEqual(audit_epoch(raw,epoch='p118',final_attempted=6,
                          final_dropped=2)['loss_notices'],1)

    def test_cli_report_created_only_on_success(self):
        raw,d=build(8)
        with tempfile.TemporaryDirectory() as td:
            capture=Path(td)/'capture.bin';capture.write_bytes(raw)
            report=Path(td)/'audit.json'
            out=io.StringIO();err=io.StringIO()
            with contextlib.redirect_stdout(out),contextlib.redirect_stderr(err):
                rc=main(['--capture',str(capture),'--epoch','e1','--final-attempted','8',
                         '--final-dropped',str(d),'--report',str(report),'--expected-tags',''])
            self.assertEqual(rc,0,err.getvalue())
            self.assertEqual(json.loads(report.read_text())['final_dropped'],d)
            self.assertEqual(capture.read_bytes(),raw)
            with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(err):
                self.assertEqual(main(['--capture',str(capture),'--epoch','e1','--final-attempted','8',
                                       '--final-dropped',str(d),'--report',str(report)]),1)

    def test_cli_invalid_does_not_write_report(self):
        raw,d=build(8)
        with tempfile.TemporaryDirectory() as td:
            capture=Path(td)/'capture.bin';capture.write_bytes(raw)
            report=Path(td)/'report.json'
            with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(['--capture',str(capture),'--epoch','e1','--final-attempted','9',
                                       '--final-dropped',str(d),'--report',str(report)]),1)
            self.assertFalse(report.exists())

    def test_cli_does_not_clobber_capture(self):
        raw,d=build(8)
        with tempfile.TemporaryDirectory() as td:
            capture=Path(td)/'capture.bin';capture.write_bytes(raw)
            with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(['--capture',str(capture),'--epoch','e1','--final-attempted','8',
                                       '--final-dropped',str(d),'--report',str(capture)]),1)
            self.assertEqual(capture.read_bytes(),raw)


if __name__=='__main__':unittest.main()
