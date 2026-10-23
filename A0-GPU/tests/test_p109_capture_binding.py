"""P109 independent evidence rehydration, epoch/batch, CLI and failure injection."""
from __future__ import annotations

import copy
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'sim'))
from a0_p107_host_batch import compile_plan
from a0_p108_transfer_guard import TransferGuard, SENDING, CAPTURE_AUDITED, verify_receipt
from a0_p109_capture_binding import verify_capture_binding, verify_epoch_batch
from a0_host_protocol_p44 import Result, encode_result
from a0_frame_telemetry_p48 import encode_frame

TOOL = ROOT/'tools/a0_p109_verify.py'


def plan(color=0x123456, base=10, *, frames=1):
    content=[]
    for i in range(frames):
        col=(color+i*0x010101) & 0xffffff
        crc=zlib.crc32(col.to_bytes(3,'little')*16)
        content.append({'clear':{'tag':base+i*3,'color':col},
                        'draws':[{'version':2 if i%2==0 else 1,
                                  **({'depth':2,'depth_op':0,'depth_write':False,
                                      'blend':False,'alpha':255,'scissor':None}
                                     if i%2==0 else {}),
                                  'tag':base+i*3+1,'color':0xffaa66,
                                  'vertices':[0,0,0,0,0,0]}],
                        'present_tag':base+i*3+2,'expected_crc32':f'0x{crc:08x}'})
    return {'schema':'A0-P107-SESSION-v1','width':4,'height':4,
            'reset_epoch':True,'frames':content}


def capture_for(session):
    results=b''.join(encode_result(Result(0,draw.command.tag,0)) for draw in session.draws)
    telemetry=b''.join(encode_frame(sequence=i,error=False,frame_crc=crc,
                              good=i+1,bad=0,aborted=0,dropped=0)
                        for i,crc in enumerate(session.expected_crcs))
    return results + telemetry


def fixture(*,epoch='reset-a',frames=1):
    spec=plan(frames=frames)
    session=compile_plan(spec)
    cap=capture_for(session)
    guard=TransferGuard(session,epoch=epoch,reset_acknowledged=True,max_chunk=18)
    while guard.status==SENDING:
        guard.poll((guard.last_tick or 0)+1,lambda b:len(b))
    audit=guard.audit(cap)
    receipt=guard.receipt()
    receipt['capture_audit']=audit
    receipt['evidence_kind']='OFFLINE_SCRIPTED_SIMULATION_NOT_HOST_CAPTURE'
    return spec,session,receipt,cap,session.wire


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.spec,self.session,self.receipt,self.capture,self.wire=fixture(frames=2)

    _missing = object()

    def verify(self,receipt=_missing,capture=_missing,wire=_missing):
        return verify_capture_binding(self.session,
             self.receipt if receipt is self._missing else receipt,
             self.capture if capture is self._missing else capture,
             self.wire if wire is self._missing else wire)

    def test_good_two_frames_and_mixed_wire(self):
        report=self.verify()
        self.assertEqual(report['status'],'PASS')
        self.assertEqual(report['frames'],2)
        self.assertEqual(report['commands'],6)
        self.assertEqual(report['sent_wire_sha256'],sha256(self.wire).hexdigest())
        self.assertEqual(report['capture_sha256'],sha256(self.capture).hexdigest())

    def test_explicitly_no_physical_proof(self):
        report=self.verify()
        for field in ('hardware_execution_proven','physical_capture_provenance_verified',
                      'physical_reset_proven','exactly_once_execution_proven'):
            self.assertIs(report[field],False)

    def test_old_receipt_passes_self_check_without_capture_audit_but_p109_rejects(self):
        bad=copy.deepcopy(self.receipt);bad.pop('capture_audit')
        self.assertEqual(verify_receipt(self.session,bad)['status'],'PASS')
        with self.assertRaisesRegex(ValueError,'lacks capture'):
            self.verify(receipt=bad)

    def test_old_receipt_self_check_accepts_forged_pass_but_p109_rejects(self):
        bad=copy.deepcopy(self.receipt)
        bad['capture_audit']={'status':'PASS'}
        self.assertEqual(verify_receipt(self.session,bad)['status'],'PASS')
        with self.assertRaises(ValueError):
            self.verify(receipt=bad)

    def test_bad_capture_metadata_fails(self):
        for field,value in [('commands',1),('frames',5),('capture_bytes',0),
                            ('requires_fresh_reset',False),('hardware_execution_proven',True),
                            ('command_sha256','0'*64),('device_reset_proven',True),
                            ('transport_state','HOST_ACCEPTED_UNVERIFIED')]:
            bad=copy.deepcopy(self.receipt)
            bad['capture_audit'][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):
                self.verify(receipt=bad)

    def test_unexpected_extra_capture_claim_rejected(self):
        bad=copy.deepcopy(self.receipt)
        bad['capture_audit']['pci_device_verified']=True
        with self.assertRaises(ValueError):
            self.verify(receipt=bad)

    def test_corrupt_capture_rejected(self):
        damaged=bytearray(self.capture);damaged[30] ^= 0x80
        with self.assertRaises(ValueError):
            self.verify(capture=bytes(damaged))

    def test_truncated_capture_rejected(self):
        with self.assertRaises(ValueError):
            self.verify(capture=self.capture[:-1])

    def test_extra_capture_packet_rejected(self):
        with self.assertRaises(ValueError):
            self.verify(capture=self.capture+self.capture[-32:])

    def test_reordered_capture_packets_rejected(self):
        bad=self.capture[16:32]+self.capture[:16]+self.capture[32:]
        with self.assertRaises(ValueError):
            self.verify(capture=bad)

    def test_wrong_wire_rejected(self):
        damaged=bytearray(self.wire);damaged[16] ^= 0x80
        with self.assertRaises(ValueError):
            self.verify(wire=bytes(damaged))

    def test_truncated_wire_rejected(self):
        with self.assertRaises(ValueError):
            self.verify(wire=self.wire[:-1])

    def test_terminal_unverified_cannot_claim_audited(self):
        bad=copy.deepcopy(self.receipt)
        bad['state']='HOST_ACCEPTED_UNVERIFIED'
        bad.pop('capture_audit')
        with self.assertRaises(ValueError):
            self.verify(receipt=bad)

    def test_partial_transmission_rejected_even_if_capture_good(self):
        spec,session,rc,cap,wire=fixture()
        rc['state']='ABORTED_UNCERTAIN'
        rc['reason']='unknown side effects'
        rc['host_accepted_bytes']=len(session.wire)//2
        with self.assertRaises(ValueError):
            verify_capture_binding(session,rc,cap,wire)

    def test_receipt_event_reordering_rejected(self):
        bad=copy.deepcopy(self.receipt)
        bad['events'][0],bad['events'][1]=bad['events'][1],bad['events'][0]
        with self.assertRaises(ValueError):
            self.verify(receipt=bad)

    def test_epoch_receipt_tamper_rejected_when_invalid(self):
        bad=copy.deepcopy(self.receipt);bad['epoch']='../../escape'
        with self.assertRaises(ValueError):
            self.verify(receipt=bad)

    def test_invalid_input_types_rejected(self):
        for receipt,capture,wire in (([],self.capture,self.wire),
                                     (self.receipt,bytearray(self.capture),self.wire),
                                     (self.receipt,self.capture,None)):
            with self.subTest((type(receipt),type(capture),type(wire))),self.assertRaises(ValueError):
                self.verify(receipt=receipt,capture=capture,wire=wire)

    def test_check_does_not_mutate_inputs(self):
        before=copy.deepcopy(self.receipt)
        self.verify()
        self.assertEqual(before,self.receipt)


class BatchTests(unittest.TestCase):
    def setUp(self):
        a=fixture(epoch='epoch-1')
        b=fixture(epoch='epoch-2',frames=2)
        self.items=[a[1:],b[1:]]

    def test_two_unique_epochs_pass(self):
        report=verify_epoch_batch(self.items)
        self.assertEqual(report['sessions'],2)
        self.assertFalse(report['physical_reset_proven'])

    def test_duplicate_epochs_rejected(self):
        b=list(self.items[1]);b[1]=copy.deepcopy(b[1]);b[1]['epoch']='epoch-1'
        with self.assertRaisesRegex(ValueError,'duplicate reset epoch'):
            verify_epoch_batch([self.items[0],tuple(b)])

    def test_second_session_invalid_fails_whole_batch(self):
        b=list(self.items[1]);b[2]=b[2][:-1]
        with self.assertRaises(ValueError):
            verify_epoch_batch([self.items[0],tuple(b)])

    def test_zero_or_oversized_batch_rejected(self):
        for items in ([],self.items*65):
            with self.assertRaises(ValueError):
                verify_epoch_batch(items)

    def test_invalid_entry_types_rejected(self):
        for entries in ([list(self.items[0])],[('too-short',)], [123]):
            with self.assertRaises(ValueError):
                verify_epoch_batch(entries)


class CLITests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.one=self.write_fixture('one','reset-one')
        self.two=self.write_fixture('two','reset-two')

    def write_fixture(self,prefix,epoch):
        spec,_,receipt,cap,wire=fixture(epoch=epoch)
        paths={key:self.root/f'{prefix}-{key}.{suffix}' for key,suffix in
               (('plan','json'),('receipt','json'),('capture','bin'),('sent_wire','bin'))}
        paths['plan'].write_text(json.dumps(spec))
        paths['receipt'].write_text(json.dumps(receipt))
        paths['capture'].write_bytes(cap)
        paths['sent_wire'].write_bytes(wire)
        return paths

    def run_cli(self,*args):
        return subprocess.run([sys.executable,str(TOOL),*map(str,args)],
                   capture_output=True,text=True,timeout=12)

    def verify_cli(self,which=None,*extra):
        p=which or self.one
        args=['verify']
        for key in ('plan','receipt','capture','sent_wire'):
            args+=['--'+key.replace('_','-'),p[key]]
        return self.run_cli(*args,*extra)

    def write_manifest(self,entries=None):
        entries = entries or [self.one,self.two]
        path=self.root/'batch.json'
        path.write_text(json.dumps({'schema':'A0-P109-BATCH-v1',
                       'sessions':[{key:p[key].name for key in p} for p in entries]}))
        return path

    def test_single_good_cli(self):
        response=self.verify_cli()
        self.assertEqual(response.returncode,0,response.stderr+response.stdout)
        self.assertEqual(json.loads(response.stdout)['status'],'PASS')

    def test_single_report_writes_only_new_output(self):
        report=self.root/'result.json'
        r=self.verify_cli(self.one,'--report',report)
        self.assertEqual(r.returncode,0,r.stdout)
        self.assertEqual(json.loads(report.read_text())['status'],'PASS')
        self.assertEqual(self.verify_cli(self.one,'--report',report).returncode,1)

    def test_single_overwrite_input_rejected(self):
        raw=self.one['capture'].read_bytes()
        self.assertEqual(self.verify_cli(self.one,'--report',self.one['capture']).returncode,1)
        self.assertEqual(self.one['capture'].read_bytes(),raw)

    def test_bad_capture_cli_fails(self):
        self.one['capture'].write_bytes(self.one['capture'].read_bytes()[:-4])
        self.assertEqual(self.verify_cli().returncode,1)

    def test_bad_receipt_claim_cli_fails(self):
        obj=json.loads(self.one['receipt'].read_text())
        obj['capture_audit']={'status':'PASS'}
        self.one['receipt'].write_text(json.dumps(obj))
        self.assertEqual(self.verify_cli().returncode,1)

    def test_batch_good_cli(self):
        result=self.run_cli('batch','--manifest',self.write_manifest())
        self.assertEqual(result.returncode,0,result.stdout)
        self.assertEqual(json.loads(result.stdout)['sessions'],2)

    def test_batch_duplicate_epoch_cli_rejected(self):
        obj=json.loads(self.two['receipt'].read_text());obj['epoch']='reset-one'
        self.two['receipt'].write_text(json.dumps(obj))
        self.assertEqual(self.run_cli('batch','--manifest',self.write_manifest()).returncode,1)

    def test_batch_manifest_escape_rejected(self):
        path=self.write_manifest()
        obj=json.loads(path.read_text());obj['sessions'][0]['capture']='../outside.bin'
        path.write_text(json.dumps(obj))
        self.assertEqual(self.run_cli('batch','--manifest',path).returncode,1)

    def test_batch_report_may_not_overwrite_input(self):
        manifest=self.write_manifest();raw=manifest.read_bytes()
        response=self.run_cli('batch','--manifest',manifest,'--report',manifest)
        self.assertEqual(response.returncode,1)
        self.assertEqual(manifest.read_bytes(),raw)

    def test_batch_bad_second_session_fails_without_report(self):
        manifest=self.write_manifest();report=self.root/'report.json'
        self.two['sent_wire'].write_bytes(b'NOT COMMANDS')
        r=self.run_cli('batch','--manifest',manifest,'--report',report)
        self.assertEqual(r.returncode,1)
        self.assertFalse(report.exists())


if __name__ == '__main__': unittest.main()
