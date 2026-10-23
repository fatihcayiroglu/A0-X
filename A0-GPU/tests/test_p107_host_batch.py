"""P107 software host batch / strict capture qualification (not RTL)."""
import copy
import json
import random
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_p107_host_batch import SCHEMA, compile_plan, audit_capture
from a0_host_extended_p106 import ExtendedCommandStreamDecoder
from a0_host_protocol_p44 import Result, encode_result
from a0_frame_telemetry_p48 import encode_frame
from a0_p106_host_fragment_reference import P106HostSession

ROOT=Path(__file__).resolve().parents[1]
CLI=ROOT/'tools/a0_p107_session.py'


def blank_frame(clear_tag, present_tag, color=0x112233, width=4, height=4):
    golden = zlib.crc32(color.to_bytes(3,'little') * (width*height))
    return {'clear':{'tag':clear_tag,'color':color},'draws':[],
            'present_tag':present_tag,'expected_crc32':f'0x{golden:08x}'}


def mixed_plan():
    a=blank_frame(1,4)
    a['draws']=[{'version':1,'tag':2,'color':0xabcdef,
                 'vertices':[0,0,0,0,0,0]},
                {'version':2,'tag':3,'color':0x445566,
                 'vertices':[0,0,0,0,0,0], 'depth':55,'depth_op':1,
                 'depth_write':True,'blend':True,'alpha':71,
                 'scissor':[0,0,2,2]}]
    # Degenerate triangles leave clear frame unchanged. The golden CRC is
    # independently calculated from a known 4x4 solid-color image.
    return {'schema':SCHEMA,'width':4,'height':4,'reset_epoch':True,
            'frames':[a,blank_frame(5,6,0x998877)]}


def synthetic_capture(session, *, interleaved=False):
    results=[encode_result(Result(0,d.command.tag,0)) for d in session.draws]
    frames=[encode_frame(sequence=i,error=False,frame_crc=crc,good=i+1,
                         bad=0,aborted=0,dropped=0)
            for i,crc in enumerate(session.expected_crcs)]
    if interleaved:
        # Results and frames may interleave arbitrarily, but order within
        # their own lane remains strictly ascending.
        return b''.join(results[:2]+frames[:1]+results[2:]+frames[1:])
    return b''.join(results+frames)


class BatchCompiler(unittest.TestCase):
    def setUp(self):
        self.plan=mixed_plan()

    def reject(self, mutation):
        p=copy.deepcopy(self.plan)
        mutation(p)
        with self.assertRaises((ValueError, TypeError)):
            compile_plan(p)

    def test_mixed_command_output_is_canonical_and_length(self):
        s=compile_plan(self.plan)
        self.assertEqual(s.command_count,6)
        self.assertEqual(len(s.wire),6*32+24)
        d=ExtendedCommandStreamDecoder()
        parsed=[]
        for n in range(0,len(s.wire),3):
            parsed.extend(d.feed(s.wire[n:n+3]))
        self.assertEqual([p.command.tag for p in parsed],[1,2,3,4,5,6])
        self.assertEqual(parsed[2].state.scissor,(0,0,2,2))
        self.assertEqual(d.invalid_frames,0)

    def test_wire_determinism_and_manifest_sha256(self):
        import hashlib
        a,b=compile_plan(self.plan),compile_plan(copy.deepcopy(self.plan))
        self.assertEqual(a,b)
        self.assertEqual(a.sha256,hashlib.sha256(a.wire).hexdigest())
        self.assertFalse(a.manifest()['rtl_qualified'])

    def test_strict_schema_and_epoch(self):
        self.reject(lambda p:p.update(schema='A0-P999'))
        self.reject(lambda p:p.update(reset_epoch=False))
        self.reject(lambda p:p.update(reset_epoch=1))
        self.reject(lambda p:p.update(extra='unexpected'))

    def test_geometry_constraints(self):
        for w,h in ((0,4),(4,0),(32768,1),(500,500),(True,4)):
            with self.subTest(w=w,h=h):
                self.reject(lambda p:p.update(width=w,height=h))

    def test_frame_list_constraints(self):
        self.reject(lambda p:p.update(frames=[]))
        self.reject(lambda p:p.update(frames={}))
        self.reject(lambda p:p.update(frames=[p['frames'][0]]*129))

    def test_duplicate_tag_across_frames(self):
        self.reject(lambda p:p['frames'][1].update(present_tag=1))

    def test_duplicate_tag_inside_frame(self):
        self.reject(lambda p:p['frames'][0].update(present_tag=2))

    def test_bool_tags_rejected(self):
        self.reject(lambda p:p['frames'][0]['clear'].update(tag=True))

    def test_malformed_draw_object_and_unknown_version(self):
        self.reject(lambda p:p['frames'][0]['draws'][0].update(version=3))
        self.reject(lambda p:p['frames'][0]['draws'][0].update(extra=7))
        self.reject(lambda p:p['frames'][0]['draws'][1].pop('scissor'))

    def test_v1_rejects_fragment_fields(self):
        self.reject(lambda p:p['frames'][0]['draws'][0].update(alpha=1))

    def test_v2_noncanonical_fields_rejected(self):
        self.reject(lambda p:p['frames'][0]['draws'][1].update(depth=0x1000000))
        self.reject(lambda p:p['frames'][0]['draws'][1].update(depth_op=True))
        self.reject(lambda p:p['frames'][0]['draws'][1].update(blend=1))
        self.reject(lambda p:p['frames'][0]['draws'][1].update(scissor=[0,0,0,3]))

    def test_invalid_crc_expectation_rejected(self):
        for v in ('1234','0xabc',-1,0x100000000,True,None):
            with self.subTest(v=v):
                self.reject(lambda p:p['frames'][0].update(expected_crc32=v))

    def test_invalid_vertices_rejected(self):
        self.reject(lambda p:p['frames'][0]['draws'][0].update(vertices=[0]*5))
        self.reject(lambda p:p['frames'][0]['draws'][0].update(vertices=[0,0,0,0,0,True]))
        self.reject(lambda p:p['frames'][0]['draws'][0].update(vertices=[0,0,0,0,0,32768]))


class StrictCapture(unittest.TestCase):
    def setUp(self):
        self.session=compile_plan(mixed_plan())
        self.wire=synthetic_capture(self.session)

    def test_success_with_fragmentation_and_lane_interleaving(self):
        capture=synthetic_capture(self.session,interleaved=True)
        for size in (1,2,7,17,64,4096):
            with self.subTest(chunk=size):
                self.assertEqual(audit_capture(self.session,capture,chunk_size=size)['status'],'PASS')

    def test_missing_result_fails(self):
        with self.assertRaisesRegex(ValueError,'result'):
            audit_capture(self.session,self.wire[16:])

    def test_duplicate_result_fails(self):
        with self.assertRaisesRegex(ValueError,'result'):
            audit_capture(self.session,self.wire[:16]+self.wire)

    def test_swapped_tags_fails(self):
        a=synthetic_capture(self.session)
        with self.assertRaisesRegex(ValueError,'tag'):
            audit_capture(self.session,a[16:32]+a[:16]+a[32:])

    def test_command_failure_fails(self):
        p=self.wire
        cmd=self.session.draws[0]
        failed=encode_result(Result(1,cmd.command.tag,0))
        with self.assertRaisesRegex(ValueError,'status'):
            audit_capture(self.session,failed+p[16:])

    def test_wrong_golden_crc_fails(self):
        plan=mixed_plan()
        plan['frames'][0]['expected_crc32']='0x00000000'
        with self.assertRaisesRegex(ValueError,'CRC'):
            audit_capture(compile_plan(plan),self.wire)

    def test_missing_or_extra_frame_fails(self):
        with self.assertRaisesRegex(ValueError,'telemetry'):
            audit_capture(self.session,self.wire[:-32])
        with self.assertRaisesRegex(ValueError,'telemetry'):
            audit_capture(self.session,self.wire+self.wire[-32:])

    def test_bad_packet_crc_and_noise_fail(self):
        p=bytearray(self.wire)
        p[20]^=1
        with self.assertRaisesRegex(ValueError,'corrupt'):
            audit_capture(self.session,bytes(p))
        with self.assertRaisesRegex(ValueError,'corrupt'):
            audit_capture(self.session,b'garbage'+self.wire)

    def test_truncated_header_and_packet_fail(self):
        for capture in (self.wire[:-1],self.wire+b'A0G',self.wire+b'A0GF'):
            with self.subTest(capture=capture[-4:]):
                with self.assertRaisesRegex(ValueError,'truncated'):
                    audit_capture(self.session,capture)

    def test_telemetry_drop_or_error_detected(self):
        results_len=16*self.session.command_count
        crc=self.session.expected_crcs[0]
        for patch in ({'dropped':1},{'error':True},{'sequence':4},{'bad':1},
                      {'good':42},{'aborted':1},{'frame_crc':crc ^ 1}):
            with self.subTest(patch=patch):
                payload=dict(sequence=0,error=False,frame_crc=crc,
                             good=1,bad=0,aborted=0,dropped=0)
                payload.update(patch)
                wire=self.wire[:results_len]+encode_frame(**payload)+self.wire[results_len+32:]
                with self.assertRaises(ValueError):
                    audit_capture(self.session,wire)

    def test_sent_wire_integrity_guard(self):
        self.assertEqual(audit_capture(self.session,self.wire,
                                       sent_wire=self.session.wire)['status'],'PASS')
        with self.assertRaisesRegex(ValueError,'differs'):
            audit_capture(self.session,self.wire,sent_wire=self.session.wire+b'\0')

    def test_type_and_chunk_guards(self):
        for data in (None,'',bytearray(self.wire)):
            with self.assertRaises(TypeError):
                audit_capture(self.session,data)
        for chunk in (0,-1,True,65537):
            with self.assertRaises(ValueError):
                audit_capture(self.session,self.wire,chunk_size=chunk)

    def test_randomized_interleaving_preserves_lanes(self):
        for seed in range(60):
            rng=random.Random(seed)
            results=[encode_result(Result(0,d.command.tag,0)) for d in self.session.draws]
            frames=[encode_frame(sequence=i,error=False,frame_crc=c,
                 good=i+1,bad=0,aborted=0,dropped=0)
                 for i,c in enumerate(self.session.expected_crcs)]
            stream=b''
            while results or frames:
                lane=rng.choice(([0] if results else [])+([1] if frames else []))
                stream+=(results if lane==0 else frames).pop(0)
            self.assertEqual(audit_capture(self.session,stream)['frames'],2)


class CLIRuntime(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d=Path(self.tmp.name)
        self.plan=d/'plan.json'
        self.capture=d/'capture.bin'
        self.wire=d/'commands.bin'
        self.manifest=d/'manifest.json'
        self.plan.write_text(json.dumps(mixed_plan()))
        self.capture.write_bytes(synthetic_capture(compile_plan(mixed_plan())))
        self.wire.write_bytes(compile_plan(mixed_plan()).wire)

    def cli(self,*args):
        return subprocess.run([sys.executable,str(CLI),*map(str,args)],
                              capture_output=True,text=True,timeout=10)

    def test_build_and_audit_success(self):
        b=self.cli('build','--plan',self.plan,'--wire',self.wire,'--manifest',self.manifest)
        self.assertEqual(b.returncode,0,b.stdout+b.stderr)
        self.assertEqual(self.wire.read_bytes(),compile_plan(mixed_plan()).wire)
        self.assertEqual(json.loads(self.manifest.read_text())['command_sha256'],
                         compile_plan(mixed_plan()).sha256)
        a=self.cli('audit','--plan',self.plan,'--sent-wire',self.wire,'--capture',self.capture)
        self.assertEqual(a.returncode,0,a.stdout+a.stderr)
        self.assertFalse(json.loads(a.stdout)['hardware_execution_proven'])

    def test_audit_rejects_corrupted_capture(self):
        self.capture.write_bytes(self.capture.read_bytes()[:-10])
        result=self.cli('audit','--plan',self.plan,'--sent-wire',self.wire,'--capture',self.capture)
        self.assertEqual(result.returncode,1)
        self.assertEqual(json.loads(result.stdout)['status'],'FAIL')

    def test_audit_rejects_command_stream_mismatch(self):
        self.wire.write_bytes(self.wire.read_bytes()+b'\0')
        result=self.cli('audit','--plan',self.plan,'--sent-wire',self.wire,'--capture',self.capture)
        self.assertEqual(result.returncode,1)
        self.assertIn('differs',json.loads(result.stdout)['reason'])

    def test_build_prevents_same_output_path(self):
        result=self.cli('build','--plan',self.plan,'--wire',self.wire,'--manifest',self.wire)
        self.assertEqual(result.returncode,1)

    def test_mixed_v2_software_reference_matches_external_goldens(self):
        session=compile_plan(mixed_plan())
        oracle=P106HostSession(4,4)
        # Explicitly slice source stream as v1/v2 packets (the first frame
        # contains a v2 command). Does NOT simulate host clocks or FPGA.
        p=0
        for draw in session.draws:
            size=56 if draw.command.tag==3 else 32
            oracle.issue(session.wire[p:p+size])
            p+=size
        self.assertEqual(p,len(session.wire))
        oracle.drain()
        self.assertEqual(audit_capture(session,oracle.capture())['status'],'PASS')

    def test_real_software_oracle_multiple_blank_frames(self):
        # Model output is ONLY synthetic reference, not hardware provenance.
        plan=mixed_plan()
        plan['frames'][0]['draws']=[]
        s=compile_plan(plan)
        oracle=P106HostSession(4,4)
        decoder=ExtendedCommandStreamDecoder()
        for draw in decoder.feed(s.wire):
            p=draw.command
            # Use exactly the original canonical wire to exercise host decoder.
            # Frame has only v1 commands, reconstructed from P44 encoder.
            from a0_host_protocol_p44 import encode_command
            oracle.issue(encode_command(p))
        oracle.drain()
        capture=oracle.capture()
        self.assertEqual(audit_capture(s,capture)['status'],'PASS')


if __name__=='__main__':unittest.main()
