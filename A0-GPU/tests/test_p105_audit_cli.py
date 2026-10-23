"""Prove a standalone independent-expected CRC capture gate fails closed."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import Command, CLEAR, PRESENT
from a0_host_protocol_p44 import encode_command
from a0_p105_host_double_bank_reference import P105HostReference

ROOT=Path(__file__).resolve().parents[1]
TOOL=ROOT/'tools/p105_capture_audit.py'

class AuditCLI(unittest.TestCase):
    def setUp(self):
        self.ctx=tempfile.TemporaryDirectory()
        self.addCleanup(self.ctx.cleanup)
        folder=Path(self.ctx.name)
        self.manifest=folder/'golden.json'
        self.capture=folder/'capture.bin'
        self.commands=[Command(CLEAR,11,0x123456,(0,)*6),Command(PRESENT,12,0,(0,)*6)]
        self.host=P105HostReference(4,4)
        for c in self.commands:self.host.send(encode_command(c))
        self.host.drain()
        self.capture.write_bytes(self.host.wire_capture())
        self.doc={'commands':[{'opcode':c.opcode,'tag':c.tag,'color':c.color,
                                'vertices':list(c.vertices)} for c in self.commands],
                  'expected_frame_crc32':[hex(self.host.frame_events[0][1])]}
        self.save()
    def save(self):self.manifest.write_text(json.dumps(self.doc))
    def run_cli(self):
        return subprocess.run([sys.executable,str(TOOL),'--manifest',str(self.manifest),
                               '--capture',str(self.capture)],capture_output=True,text=True)
    def test_correct_external_capture_passes(self):
        p=self.run_cli()
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual(json.loads(p.stdout)['status'],'PASS')
    def test_wrong_golden_crc_fails(self):
        self.doc['expected_frame_crc32']=['0x0'];self.save()
        p=self.run_cli()
        self.assertEqual(p.returncode,1)
        self.assertEqual(json.loads(p.stdout)['status'],'FAIL')
    def test_ambiguous_duplicate_tag_fails(self):
        self.doc['commands'][1]['tag']=11;self.save()
        self.assertEqual(self.run_cli().returncode,1)
    def test_truncated_capture_fails(self):
        self.capture.write_bytes(self.capture.read_bytes()[:-2])
        self.assertEqual(self.run_cli().returncode,1)
    def test_noncanonical_manifest_fails(self):
        self.doc['commands'][1]['color']=1;self.save()
        self.assertEqual(self.run_cli().returncode,1)

if __name__=='__main__':unittest.main()
