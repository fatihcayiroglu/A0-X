"""Pure software checks on a P50 HDL stimulus/reference trace.

These tests do NOT establish RTL correctness; only the real HDL gate does.
"""
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from a0_fair_trace_p50 import build_trace,verify_trace

class P50TraceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data,cls.coverage=build_trace(seed=50050,cycles=6000)

    def test_seed_reproducible(self):
        d,c=build_trace(seed=50050,cycles=6000)
        self.assertEqual(d,self.data)
        self.assertEqual(c,self.coverage)

    def test_software_oracle_replays_generated_trace(self):
        r=verify_trace(self.data)
        self.assertEqual(r['cycles'],6000)
        self.assertEqual(r['sha256'],self.coverage['sha256'])

    def test_multiple_seeds_exercise_contention_and_recovery(self):
        for seed in [1,2,137,65535]:
            with self.subTest(seed=seed):
                d,c=build_trace(seed=seed,cycles=3000)
                self.assertGreater(c['both_valid_cycles'],100)
                self.assertGreater(c['host_stalls'],100)
                self.assertGreater(c['completed_telemetry_frames'],20)
                self.assertGreater(c['completed_result_frames'],20)
                verify_trace(d)

    def test_detect_modified_expected_byte(self):
        lines=self.data.splitlines()
        for idx,line in enumerate(lines[1:],1):
            fields=line.split()
            if fields[6]=='1':
                fields[7]=str((int(fields[7])+1)%256)
                lines[idx]=' '.join(fields)
                break
        with self.assertRaisesRegex(ValueError,'software oracle'):
            verify_trace('\n'.join(lines)+'\n')

    def test_detect_modified_valid(self):
        lines=self.data.splitlines()
        for idx,line in enumerate(lines[1:],1):
            fields=line.split()
            if fields[6]=='1':
                fields[6]='0'
                lines[idx]=' '.join(fields)
                break
        with self.assertRaisesRegex(ValueError,'software oracle'):
            verify_trace('\n'.join(lines)+'\n')

    def test_detect_incorrect_ready(self):
        lines=self.data.splitlines()
        for idx,line in enumerate(lines[1:],1):
            fields=line.split()
            if fields[8]=='1':
                fields[8]='0'
                lines[idx]=' '.join(fields)
                break
        with self.assertRaisesRegex(ValueError,'software oracle'):
            verify_trace('\n'.join(lines)+'\n')

    def test_detect_invalid_boolean_and_byte(self):
        lines=self.data.splitlines()
        fields=lines[10].split(); fields[1]='2'; lines[10]=' '.join(fields)
        with self.assertRaisesRegex(ValueError,'boolean out of range'):
            verify_trace('\n'.join(lines)+'\n')
        lines=self.data.splitlines()
        fields=lines[10].split(); fields[2]='256';lines[10]=' '.join(fields)
        with self.assertRaisesRegex(ValueError,'byte out of range'):
            verify_trace('\n'.join(lines)+'\n')

    def test_detect_malformed_truncated_trace(self):
        with self.assertRaisesRegex(ValueError,'expected 10 columns'):
            verify_trace(self.data+'1 1 1\n')

    def test_detect_source_handshake_violation(self):
        lines=self.data.splitlines()
        for i in range(2,len(lines)-1):
            prev=lines[i-1].split(); cur=lines[i].split()
            # previous result valid while result not ready; next source must hold
            if prev[0]=='1' and prev[1]=='1' and prev[8]=='0' and cur[0]=='1' and cur[1]=='1':
                cur[2]=str((int(cur[2])+1)%256)
                lines[i]=' '.join(cur)
                break
        else:
            self.fail('vacuous test: no held result source found')
        with self.assertRaisesRegex(ValueError,'source violated held valid/data'):
            verify_trace('\n'.join(lines)+'\n')

    def test_accepted_wire_frames_decode_with_real_crc_and_reset_boundaries(self):
        from a0_host_stream_p49 import HostStreamDecoder
        records=[]
        incomplete_epochs=0
        d=HostStreamDecoder()
        for raw in self.data.splitlines()[1:]:
            rst,rv,rb,tv,tb,ready,ev,eb,err,etr = map(int,raw.split())
            if not rst:
                incomplete_epochs += int(bool(d.finish()['incomplete_tail_bytes']))
                d=HostStreamDecoder()
            elif ready and ev:
                records.extend(d.feed(bytes([eb])))
        incomplete_epochs += int(bool(d.finish()['incomplete_tail_bytes']))
        results=[r for r in records if r['kind']=='result']
        frames=[r for r in records if r['kind']=='frame']
        self.assertGreaterEqual(len(results),60)
        self.assertGreaterEqual(len(frames),60)
        self.assertEqual(d.invalid_candidates,0)
        self.assertLessEqual(incomplete_epochs,3)

    def test_trace_coverage_includes_solo_and_both(self):
        rows=[list(map(int,x.split())) for x in self.data.splitlines()[1:]]
        self.assertTrue(any(r[1] and not r[3] for r in rows))
        self.assertTrue(any(r[3] and not r[1] for r in rows))
        self.assertTrue(any(r[1] and r[3] for r in rows))
        self.assertTrue(any(r[5]==0 and r[6] for r in rows))
        self.assertEqual(sum(r[0]==0 for r in rows),5)
        self.assertGreater(self.coverage['result_grants'],50)
        self.assertGreater(self.coverage['telemetry_grants'],50)

if __name__=='__main__':unittest.main()
