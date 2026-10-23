"""P108 failure-state host transport model tests (software only)."""
import hashlib
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p107_host_batch import compile_plan
from a0_p108_transfer_guard import (TransferGuard, SENDING, HOST_ACCEPTED_UNVERIFIED,
    ABORTED_NO_PROGRESS, ABORTED_UNCERTAIN, CAPTURE_AUDITED)
from a0_host_protocol_p44 import Result, encode_result
from a0_frame_telemetry_p48 import encode_frame

TOOL=ROOT/'tools/a0_p108_transfer.py'


def plan():
    color=0x112233
    crc=zlib.crc32(color.to_bytes(3,'little')*16)
    return {'schema':'A0-P107-SESSION-v1','width':4,'height':4,'reset_epoch':True,
            'frames':[{'clear':{'tag':1,'color':color},
                       'draws':[{'version':2,'tag':2,'color':0x456789,
                       'vertices':[0,0,0,0,0,0],'depth':44,'depth_op':0,
                       'depth_write':False,'blend':False,'alpha':255,'scissor':None}],
                       'present_tag':3,'expected_crc32':f'0x{crc:08x}'}]}


def valid_capture(session):
    return b''.join(encode_result(Result(0,d.command.tag,0)) for d in session.draws) + \
        encode_frame(sequence=0,error=False,frame_crc=session.expected_crcs[0],
                     good=1,bad=0,aborted=0,dropped=0)


class TransferGuardTests(unittest.TestCase):
    def setUp(self):
        self.session=compile_plan(plan())
        self.g=TransferGuard(self.session,epoch='demo-1',reset_acknowledged=True,
                             max_chunk=11,timeout_ticks=5)

    def complete(self, guard=None):
        guard = guard or self.g
        for tick in range(1,200):
            if guard.status != SENDING:
                break
            guard.poll(tick,lambda data:len(data))
        self.assertEqual(guard.status,HOST_ACCEPTED_UNVERIFIED)
        return guard

    def test_complete_mixed_packets_never_crosses_a_boundary(self):
        chunks=[]
        while self.g.status == SENDING:
            tick=(self.g.last_tick or 0)+1
            self.g.poll(tick,lambda offered:chunks.append(offered) or len(offered))
        self.assertEqual(b''.join(chunks),self.session.wire)
        self.assertEqual(self.g.packet_ends,[32,88,120])
        self.assertEqual(self.g.accepted,120)
        self.assertTrue(all(x.offered <= 11 for x in self.g.events))
        self.assertEqual(self.g.receipt()['accepted_prefix_sha256'],self.session.sha256)

    def test_partial_positive_writes_continue_without_duplication(self):
        chunks=[]
        while self.g.status == SENDING:
            self.g.poll((self.g.last_tick or 0)+1,
                        lambda data:chunks.append(data[:2]) or min(2,len(data)))
        self.assertEqual(b''.join(chunks),self.session.wire)
        self.assertEqual(sum(e.accepted for e in self.g.events),len(self.session.wire))

    def test_zero_writes_recover_if_before_timeout(self):
        self.g.poll(1,lambda b:0)
        self.g.poll(2,lambda b:0)
        self.assertEqual(self.g.status,SENDING)
        self.g.poll(3,lambda b:len(b))
        self.assertEqual(self.g.accepted,11)

    def test_zero_progress_timeout_is_clean_but_needs_new_epoch(self):
        for tick in range(1,6):
            self.g.poll(tick,lambda data:0)
        self.assertEqual(self.g.poll(6,lambda data:len(data)),ABORTED_NO_PROGRESS)
        self.assertEqual(self.g.accepted,0)
        self.assertFalse(self.g.receipt()['can_resume_without_fresh_reset'])
        with self.assertRaises(RuntimeError):
            self.g.poll(7,lambda data:len(data))

    def test_partial_then_timeout_is_uncertain(self):
        self.g.poll(1,lambda b:3)
        for tick in range(2,6):
            self.g.poll(tick,lambda b:0)
        self.assertEqual(self.g.poll(6,lambda b:len(b)),ABORTED_UNCERTAIN)
        self.assertEqual(self.g.accepted,3)
        self.assertFalse(self.g.receipt()['automatic_replay_permitted'])

    def test_writer_exception_before_known_progress_is_uncertain(self):
        def fail(data):
            raise OSError('simulated write raised after hidden side effect')
        self.assertEqual(self.g.poll(1,fail),ABORTED_UNCERTAIN)
        self.assertEqual(self.g.accepted,0)

    def test_writer_exception_after_partial_is_uncertain(self):
        self.g.poll(1,lambda b:2)
        self.assertEqual(self.g.poll(2,lambda b:1//0),ABORTED_UNCERTAIN)
        self.assertEqual(self.g.accepted,2)
        with self.assertRaises(RuntimeError):
            self.g.audit(valid_capture(self.session))

    def test_invalid_writer_counts_fail_closed(self):
        for result in (-1,12,True,None,1.0,'3',b'3'):
            with self.subTest(result=result):
                g=TransferGuard(self.session,epoch='test',reset_acknowledged=True,max_chunk=11)
                self.assertEqual(g.poll(1,lambda b:result),ABORTED_UNCERTAIN)

    def test_invalid_epoch_and_parameters(self):
        for kwargs in ({'epoch':''},{'epoch':'x'*65},{'epoch':'../path'},
                       {'epoch':3},{'reset_acknowledged':False},
                       {'reset_acknowledged':1},{'max_chunk':0},{'max_chunk':True},
                       {'timeout_ticks':True},{'timeout_ticks':0}):
            base=dict(epoch='ok',reset_acknowledged=True)
            base.update(kwargs)
            with self.subTest(base=base),self.assertRaises((ValueError,TypeError)):
                TransferGuard(self.session,**base)

    def test_tick_rollback_and_types_rejected_without_progress(self):
        for invalid in (-1,True,2.0,'2'):
            with self.subTest(invalid=invalid),self.assertRaises(ValueError):
                self.g.poll(invalid,lambda b:len(b))
        self.g.poll(1,lambda b:2)
        for invalid in (1,0):
            with self.assertRaises(ValueError):
                self.g.poll(invalid,lambda b:len(b))
        self.assertEqual(self.g.accepted,2)

    def test_requires_callable_writer(self):
        with self.assertRaises(TypeError):
            self.g.poll(1,None)
        self.assertIsNone(self.g.last_tick)

    def test_no_audit_before_transfer_completion(self):
        with self.assertRaises(RuntimeError):
            self.g.audit(valid_capture(self.session))

    def test_successful_capture_audit_remains_software_only(self):
        self.complete()
        result=self.g.audit(valid_capture(self.session))
        self.assertEqual(result['status'],'PASS')
        self.assertFalse(result['hardware_execution_proven'])
        self.assertFalse(result['device_reset_proven'])
        self.assertEqual(self.g.status,CAPTURE_AUDITED)
        with self.assertRaises(RuntimeError):
            self.g.audit(valid_capture(self.session))

    def test_bad_capture_fails_without_false_success(self):
        self.complete()
        with self.assertRaises(ValueError):
            self.g.audit(valid_capture(self.session)[:-1])
        self.assertEqual(self.g.status,HOST_ACCEPTED_UNVERIFIED)

    def test_receipt_logs_exact_prefix_hash_at_each_accepted_write(self):
        self.g.poll(1,lambda b:4)
        self.g.poll(2,lambda b:0)
        self.g.poll(3,lambda b:7)
        events=self.g.receipt()['events']
        self.assertEqual(len(events),2)
        self.assertEqual(events[0]['prefix_sha256'],hashlib.sha256(self.session.wire[:4]).hexdigest())
        self.assertEqual(events[1]['prefix_sha256'],hashlib.sha256(self.session.wire[:11]).hexdigest())

    def test_randomized_partial_acceptance_preserves_exact_wire(self):
        for seed in range(30):
            rng=random.Random(seed)
            g=TransferGuard(self.session,epoch='random',reset_acknowledged=True,
                            max_chunk=30,timeout_ticks=200)
            accepted=[]
            while g.status==SENDING:
                t=(g.last_tick or 0)+1
                def write(data):
                    n=rng.randrange(len(data)+1)
                    accepted.append(data[:n]);return n
                g.poll(t,write)
            self.assertEqual(b''.join(accepted),self.session.wire)
            self.assertFalse(g.receipt()['hardware_execution_proven'])


class TransferCLI(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.d=Path(self.tmp.name)
        self.plan=self.d/'plan.json'; self.plan.write_text(json.dumps(plan()))
        self.events=self.d/'events.json'; self.receipt=self.d/'receipt.json'
        self.capture=self.d/'capture.bin'
        self.capture.write_bytes(valid_capture(compile_plan(plan())))

    def cli(self,*rest):
        return subprocess.run([sys.executable,str(TOOL),'simulate',
             '--plan',str(self.plan),'--events',str(self.events),
             '--receipt',str(self.receipt),'--chunk','56','--timeout','4',
             *rest],text=True,capture_output=True,timeout=8)

    def test_complete_offline_acceptance_without_capture_not_proof(self):
        self.events.write_text(json.dumps([{'tick':i,'accept':n}
                           for i,n in ((1,32),(2,56),(3,32))]))
        r=self.cli();self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        receipt=json.loads(self.receipt.read_text())
        self.assertEqual(receipt['state'],HOST_ACCEPTED_UNVERIFIED)
        self.assertEqual(receipt['evidence_kind'],'OFFLINE_SCRIPTED_SIMULATION_NOT_HOST_CAPTURE')

    def test_complete_and_capture_audit(self):
        self.events.write_text(json.dumps([{'tick':i,'accept':n}
                           for i,n in ((1,32),(2,56),(3,32))]))
        r=self.cli('--capture',str(self.capture))
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(json.loads(self.receipt.read_text())['capture_audit']['status'],'PASS')

    def test_partial_then_timeout_fails(self):
        self.events.write_text(json.dumps([{'tick':1,'accept':3},
                                           {'tick':2,'accept':0},
                                           {'tick':5,'accept':0}]))
        r=self.cli();self.assertEqual(r.returncode,1)
        self.assertEqual(json.loads(self.receipt.read_text())['state'],ABORTED_UNCERTAIN)

    def test_simulated_fault_fails_closed(self):
        self.events.write_text(json.dumps([{'tick':1,'fault':'io_error'}]))
        r=self.cli();self.assertEqual(r.returncode,1)
        self.assertEqual(json.loads(self.receipt.read_text())['state'],ABORTED_UNCERTAIN)

    def test_invalid_event_schema_and_terminal_extra_event(self):
        for events in ([{'tick':1,'accept':1,'extra':2}],
                       [{'tick':1,'fault':'not-real'}],
                       [{'tick':1,'accept':32},{'tick':2,'accept':56},
                        {'tick':3,'accept':32},{'tick':4,'accept':1}]):
            self.events.write_text(json.dumps(events))
            with self.subTest(events=events):
                self.assertEqual(self.cli().returncode,1)

    def test_receipt_does_not_overwrite_plan(self):
        self.events.write_text(json.dumps([{'tick':1,'accept':0}]))
        original=self.plan.read_bytes()
        r=self.cli('--epoch','demo')
        self.assertEqual(r.returncode,1)  # incomplete attempted session
        self.assertEqual(self.plan.read_bytes(),original)
        cmd=[sys.executable,str(TOOL),'simulate','--plan',str(self.plan),
             '--events',str(self.events),'--receipt',str(self.plan)]
        p=subprocess.run(cmd,text=True,capture_output=True,timeout=8)
        self.assertEqual(p.returncode,1)
        self.assertEqual(self.plan.read_bytes(),original)

class ReceiptConsistencyTests(unittest.TestCase):
    def setUp(self):
        self.s=compile_plan(plan())
        self.g=TransferGuard(self.s,epoch='receipt-check',reset_acknowledged=True,max_chunk=32)

    def test_valid_in_progress_and_complete_receipts(self):
        from a0_p108_transfer_guard import verify_receipt
        self.assertTrue(verify_receipt(self.s,self.g.receipt())['internally_consistent'])
        while self.g.status==SENDING:
            self.g.poll((self.g.last_tick or 0)+1,lambda data:len(data))
        self.assertFalse(verify_receipt(self.s,self.g.receipt())['provenance_verified'])

    def test_mutation_of_journal_rejected(self):
        import copy
        from a0_p108_transfer_guard import verify_receipt
        self.g.poll(1,lambda data:15)
        good=self.g.receipt()
        mutations=[('planned_sha256','0'*64),('host_accepted_bytes',16),
                   ('accepted_prefix_sha256','0'*64),('automatic_replay_permitted',True),
                   ('hardware_execution_proven',True),('can_resume_without_fresh_reset',False),
                   ('state',HOST_ACCEPTED_UNVERIFIED),('schema','other')]
        for k,value in mutations:
            bad=copy.deepcopy(good);bad[k]=value
            with self.subTest(k=k),self.assertRaises(ValueError):
                verify_receipt(self.s,bad)
        for key, value in [('accepted',16),('offset',2),('offered',1024),
                            ('packet',1),('prefix_sha256','0'*64),('tick',True)]:
            bad=copy.deepcopy(good);bad['events'][0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):
                verify_receipt(self.s,bad)

    def test_log_cannot_cross_command_boundary(self):
        from a0_p108_transfer_guard import verify_receipt
        self.g.poll(1,lambda b:32)
        self.g.poll(2,lambda b:32)
        self.g.poll(3,lambda b:24)
        self.assertEqual(verify_receipt(self.s,self.g.receipt())['accepted_bytes'],88)

    def test_receipt_aborted_uncertain_accepts_consistent_prefix(self):
        from a0_p108_transfer_guard import verify_receipt
        self.g.poll(1,lambda b:6)
        self.g.poll(2,lambda b:None)
        self.assertTrue(verify_receipt(self.s,self.g.receipt())['internally_consistent'])


class ReceiptCLI(unittest.TestCase):
    def test_verify_subcommand_refuses_tampered_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            d=Path(root);plan_path=d/'plan.json';receipt=d/'receipt.json'
            plan_path.write_text(json.dumps(plan()))
            session=compile_plan(plan())
            guard=TransferGuard(session,epoch='verify',reset_acknowledged=True)
            guard.poll(1,lambda data:len(data))
            receipt.write_text(json.dumps(guard.receipt()))
            command=[sys.executable,str(TOOL),'verify','--plan',str(plan_path),
                     '--receipt',str(receipt)]
            r=subprocess.run(command,text=True,capture_output=True,timeout=8)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertFalse(json.loads(r.stdout)['provenance_verified'])
            bad=json.loads(receipt.read_text());bad['events'][0]['accepted']=0
            receipt.write_text(json.dumps(bad))
            r=subprocess.run(command,text=True,capture_output=True,timeout=8)
            self.assertEqual(r.returncode,1,r.stdout+r.stderr)
            self.assertEqual(json.loads(r.stdout)['status'],'FAIL')
