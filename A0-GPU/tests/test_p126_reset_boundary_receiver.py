"""P126 host-side epoch-isolation regressions; NEVER real RTL evidence."""
from __future__ import annotations
import random
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
from a0_p126_reset_boundary_receiver import ResetBoundaryReceiver
from a0_p119_epoch_reconcile import EpochReconciler
from a0_p122_packet_oracle import frame, loss_notice
import run_p125_depth7_ring_reset as old

FIRST = b''.join(old.EXPECTED[:9]) + old.ABORTED[:9]
NEW = old.NEW


def cross(receiver: ResetBoundaryReceiver, label='epoch-1', evidence='hw-reset-001', index=1,
          reset=True, idle=True):
    return receiver.reset_boundary(new_epoch=label, evidence_id=evidence,
          boundary_index=index, reset_asserted=reset, transmitter_quiesced=idle)


class ReceiverTest(unittest.TestCase):
    def test_p125_actual_scenario_expected_wire_bytes(self):
        r=ResetBoundaryReceiver('epoch-0')
        r.feed(FIRST)
        info=cross(r)
        self.assertEqual((info['completed_packets_before_abort'], info['discarded_partial_bytes']), (9,9))
        self.assertEqual(info['discarded_partial_hex'],old.ABORTED[:9].hex())
        r.feed(NEW)
        result=r.finalize(final_attempted=1,final_dropped=0)
        self.assertEqual(result['latest']['packet_count'],1)
        self.assertEqual(result['latest']['accepted_frame_packets'],1)
        self.assertEqual(result['latest']['byte_count'],32)
        self.assertEqual(result['aborted_epoch_count'],1)
        self.assertFalse(result['all_epochs_reconciled'])
        self.assertFalse(result['physical_hardware_verified'])
        self.assertFalse(result['reset_proven'])
        self.assertFalse(result['external_counters_authenticated'])

    def test_chunking_does_not_affect_reset_epoch(self):
        for seed in range(20):
            r=ResetBoundaryReceiver('e0');rand=random.Random(seed)
            off=0
            while off<len(FIRST):
                n=rand.randint(1,45);r.feed(FIRST[off:off+n]);off+=n
            info=cross(r)
            self.assertEqual(info['discarded_partial_bytes'],9)
            off=0
            while off<len(NEW):
                n=rand.randint(1,9);r.feed(NEW[off:off+n]);off+=n
            self.assertEqual(r.finalize(final_attempted=1,final_dropped=0)['latest']['packet_count'],1)

    def test_splicing_without_boundary_poisons_receiver(self):
        r=ResetBoundaryReceiver('e0')
        r.feed(FIRST)
        with self.assertRaises(ValueError):r.feed(NEW)
        with self.assertRaisesRegex(ValueError,'invalidated'):cross(r)
        with self.assertRaisesRegex(ValueError,'invalidated'):
            r.finalize(final_attempted=1,final_dropped=0)

    def test_reject_unacknowledged_boundary_without_discarding(self):
        for reset,idle in ((False,True),(True,False),(False,False),(1,True),(True,1),('yes',True)):
            with self.subTest(reset=reset,idle=idle):
                r=ResetBoundaryReceiver('e0');r.feed(FIRST)
                with self.assertRaisesRegex(ValueError,'acknowledgments'):
                    cross(r,reset=reset,idle=idle)
                # Rejected reset does not mutate buffer or allow silent discard.
                with self.assertRaisesRegex(ValueError,'truncated'):
                    r.finalize(final_attempted=9,final_dropped=2)

    def test_reject_duplicate_epoch_and_evidence(self):
        r=ResetBoundaryReceiver('e0')
        cross(r)
        with self.assertRaisesRegex(ValueError,'replay'):
            cross(r,label='e0',evidence='hw-reset-002',index=2)
        with self.assertRaisesRegex(ValueError,'replay'):
            cross(r,label='e2',evidence='hw-reset-001',index=2)
        cross(r,label='e2',evidence='hw-reset-002',index=2)
        result=r.finalize(final_attempted=0,final_dropped=0)
        self.assertEqual(result['aborted_epoch_count'],2)

    def test_reject_invalid_indices_without_mutation(self):
        for i in (0,-1,2,True,1.0,'1'):
            r=ResetBoundaryReceiver('e0')
            with self.subTest(i=i):
                with self.assertRaises(ValueError):cross(r,index=i)
                self.assertEqual(cross(r)['boundary_index'],1)

    def test_reject_invalid_audit_ids(self):
        for key in ('', 'a b', 'x'*129, None, True, '🔥', '\nreset'):
            with self.subTest(key=key):
                with self.assertRaises(ValueError):ResetBoundaryReceiver(key)
                r=ResetBoundaryReceiver('e0')
                with self.assertRaises(ValueError):cross(r,label=key)
                with self.assertRaises(ValueError):cross(r,evidence=key)

    def test_reject_non_bytes_and_poison(self):
        r=ResetBoundaryReceiver('e0')
        with self.assertRaisesRegex(ValueError,'bytes'):r.feed(bytearray(NEW))
        with self.assertRaisesRegex(ValueError,'invalidated'):r.feed(NEW)
        with self.assertRaisesRegex(ValueError,'invalidated'):cross(r)

    def test_valid_chunked_epoch_without_reset(self):
        r=ResetBoundaryReceiver('e0')
        for b in NEW:r.feed(bytes([b]))
        report=r.finalize(final_attempted=1,final_dropped=0)
        self.assertEqual(report['aborted_epoch_count'],0)
        self.assertTrue(report['all_epochs_reconciled'])

    def test_crc_corruption_new_epoch_poisoned(self):
        corrupt=bytearray(NEW);corrupt[-1]^=0x20
        r=ResetBoundaryReceiver('e0');cross(r)
        with self.assertRaises(ValueError):r.feed(bytes(corrupt))
        with self.assertRaisesRegex(ValueError,'invalidated'):
            r.finalize(final_attempted=1,final_dropped=0)

    def test_same_partial_suffix_rejected_after_reset(self):
        r=ResetBoundaryReceiver('e0');r.feed(FIRST);cross(r)
        # New epoch may not use the old packet's remaining 23 bytes to
        # reconstitute the former epoch's incomplete frame.
        with self.assertRaises(ValueError):r.feed(old.ABORTED[9:])

    def test_bad_latest_final_counters_fail_terminal(self):
        r=ResetBoundaryReceiver('e0');cross(r);r.feed(NEW)
        with self.assertRaises(ValueError):r.finalize(final_attempted=2,final_dropped=0)
        with self.assertRaisesRegex(ValueError,'closed'):
            r.finalize(final_attempted=1,final_dropped=0)

    def test_closed_session_no_more_boundary_or_bytes(self):
        r=ResetBoundaryReceiver('e0');r.feed(NEW)
        r.finalize(final_attempted=1,final_dropped=0)
        with self.assertRaisesRegex(ValueError,'closed'):r.feed(NEW)
        with self.assertRaisesRegex(ValueError,'closed'):cross(r)

    def test_return_value_does_not_alias_internal_history(self):
        r=ResetBoundaryReceiver('e0')
        event=cross(r)
        event['discarded_partial_hex']='tampered'
        report=r.finalize(final_attempted=0,final_dropped=0)
        self.assertEqual(report['aborted_epochs'][0]['discarded_partial_hex'],'')

    def test_pre_reset_counters_are_not_latest_epoch(self):
        r=ResetBoundaryReceiver('e0');r.feed(FIRST);cross(r);r.feed(NEW)
        with self.assertRaises(ValueError):r.finalize(final_attempted=10,final_dropped=2)

    def test_empty_reset_epoch_and_contiguous_restarts(self):
        r=ResetBoundaryReceiver('e0')
        cross(r);cross(r,label='e2',evidence='hw-reset-002',index=2)
        r.feed(NEW)
        report=r.finalize(final_attempted=1,final_dropped=0)
        self.assertEqual(report['aborted_epoch_count'],2)
        self.assertEqual([e['discarded_partial_bytes'] for e in report['aborted_epochs']],[0,0])

    def test_parser_integration_not_fake_pass(self):
        # The reconciler must recognize the nine valid pre-reset packets,
        # but must NOT allow finalizing the trailing nine-byte fragment.
        raw=EpochReconciler('e0')
        raw.feed(FIRST)
        self.assertEqual(raw.total_packets,9)
        with self.assertRaisesRegex(ValueError,'truncated'):
            raw.finalize(final_attempted=9,final_dropped=2)
        self.assertEqual(len(old.EXPECTED),10)
        self.assertEqual(NEW,frame(sequence=0,frame_crc=0xD600000B,error=False,
                    good=4,bad=5,aborted=6))
        self.assertEqual(old.EXPECTED[7],loss_notice(sequence=8,dropped=1,good=40,bad=50,aborted=60))

if __name__=='__main__':unittest.main()
