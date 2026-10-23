"""Validate independent golden host/CRC vector contract; NOT an RTL run."""
import pathlib
import re
import sys
import unittest
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
from a0_graphics_command_p43 import CLEAR, PRESENT, TRIANGLE, Command
from a0_host_protocol_p44 import encode_command, ProtocolError
from a0_host_extended_p106 import decode_host_command

SV = ROOT / 'tests' / 'rtl' / 'a0_host_frame_audit_e2e_p116_tb.sv'


def packets():
    s = SV.read_text()
    return [int(h, 16).to_bytes(int(n), 'little')
            for h, n in re.findall(r'send_packet\(448\'h([0-9a-f]+),(32|56)\)', s)]


def gold_crc(colors):
    return zlib.crc32(b''.join(int(c).to_bytes(3, 'little') for c in colors))


class E2EVectorTests(unittest.TestCase):
    def test_six_packets_and_tags(self):
        p = packets()
        self.assertEqual(list(map(len, p)), [32, 56, 56, 32, 32, 32])
        self.assertEqual([decode_host_command(x).command.tag for x in
                          (p[0], p[1], p[3], p[4], p[5])], [1, 2, 3, 4, 5])

    def test_legacy_encoded_without_manual_crc(self):
        p = packets()
        for pkt, cmd in [(p[0], Command(CLEAR, 1, 0x112233, (0,)*6)),
                         (p[3], Command(PRESENT, 3, 0, (0,)*6)),
                         (p[4], Command(CLEAR, 4, 0x445566, (0,)*6)),
                         (p[5], Command(PRESENT, 5, 0, (0,)*6))]:
            self.assertEqual(pkt, encode_command(cmd))

    def test_corrupted_triangle_rejected_not_dispatched(self):
        p = packets()
        self.assertEqual(p[1][5], TRIANGLE)
        with self.assertRaisesRegex(ProtocolError, 'CRC'):
            decode_host_command(p[2])
        a=decode_host_command(p[1])
        self.assertEqual(a.command.tag, 2)
        self.assertTrue(a.state.blend)
        self.assertEqual(a.state.scissor, (1, 1, 2, 2))
        self.assertEqual(a.state.alpha, 128)
        self.assertNotEqual(p[1], p[2])

    def test_independent_pixel_crc_not_derived_from_dut(self):
        self.assertEqual(gold_crc([0x881119 if i == 5 else 0x112233
                                   for i in range(16)]), 0x0b207310)
        self.assertEqual(gold_crc([0x445566]*16), 0x330e6e51)
        txt=SV.read_text()
        self.assertIn("GOLD_CRC0=32'h0b207310",txt)
        self.assertIn("GOLD_CRC1=32'h330e6e51",txt)

    def test_checks_each_data_boundary_and_all_monitors(self):
        txt=SV.read_text()
        for x in ('pixel_valid && pixel_ready', 'tx_valid && tx_ready',
                  'registered_frame_events!=2', 'audit_matched_good_frames!==2',
                  'frame_liveness_completed!==2', 'frame_liveness_pixels!==32',
                  'frame_liveness_stalls<12', 'telemetry_dropped_frames!==0',
                  'results!=5 || telemetry!=2', 'crc_bytes(offset,len-4)',
                  "captured[offset+12]!==8'(telemetry)",
                  "captured[offset+6]!==8'(telemetry-1)",
                  'pixel_ready=0', 'send_packet',
                  'P116_REAL_RTL_HOST_FRAME_AUDIT_E2E_PASS'):
            self.assertIn(x,txt)

    def test_two_frame_reference_pipeline_matches_golden(self):
        from a0_p106_host_fragment_reference import P106HostSession
        from a0_host_protocol_p44 import decode_result
        src=packets()
        session=P106HostSession(4,4)
        # Command 3 has intentionally corrupt CRC; never call issue on it.
        for idx in (0,1,3,4,5):
            result=decode_result(session.issue(src[idx]))
            self.assertEqual(result.status,0)
        session.drain()
        self.assertEqual(len(session.pixels),32)
        self.assertEqual(len(session.telemetry),2)
        self.assertEqual([gold_crc([p.color for p in session.pixels[i:i+16]])
                          for i in (0,16)], [0x0b207310,0x330e6e51])

    def test_golden_drift_is_detected(self):
        v=[0x112233]*16
        expected=gold_crc(v)
        v[0]=0x112232
        self.assertNotEqual(expected,gold_crc(v))
        self.assertNotEqual(gold_crc([0x445566]*16),gold_crc([0x445567]*16))

    def test_all_outputs_of_p115_wrapper_explicit(self):
        # A 2-frame qualified bench should not silently omit a monitor port.
        source=(ROOT/'rtl'/'graphics'/'a0_host_fragment_dual_bank_frame_audit_p115.sv').read_text()
        header=source.split(')(\n',1)[1].split('\n);',1)[0]
        ports=[re.search(r'([A-Za-z_]\w*)\s*$', item).group(1)
               for item in header.split(',')]
        self.assertGreater(len(ports), 55)
        bench=SV.read_text()
        for port in ports:
            self.assertRegex(bench, rf'\b{re.escape(port)}\b')

if __name__ == '__main__': unittest.main()
