"""P115 wrapper must retain every inherited P114 pin exactly once."""
from pathlib import Path
import re,unittest
ROOT=Path(__file__).resolve().parents[1]
RTL=ROOT/'rtl/graphics'
P114=(RTL/'a0_host_fragment_dual_bank_diagnostics_p114.sv').read_text()
P115=(RTL/'a0_host_fragment_dual_bank_frame_audit_p115.sv').read_text()
MON=(RTL/'a0_frame_event_audit_p115.sv').read_text()

def get_pins(src):
    header=src[src.index('module '):src.index(');')]
    p=[]
    for l in header.splitlines():
        l=l.strip()
        if l.startswith(('input logic','output logic')):
            l=re.sub(r'^(?:input|output)\s+logic\s*','',l)
            l=re.sub(r'^\[[^]]+\]\s*','',l).rstrip(',')
            p.extend(x.strip() for x in l.split(','))
    return p

class WrapperTests(unittest.TestCase):
    def test_port_preservation(self):
        old=get_pins(P114);new=get_pins(P115)
        self.assertEqual(new[:len(old)],old)
        self.assertEqual(len(old),51)
        self.assertEqual(len(new),60)
        self.assertEqual(len(set(new)),len(new))
    def test_binding_exact(self):
        old=get_pins(P114)
        conn=P115.split(') inherited_graphics (',1)[1].split(');',1)[0]
        bindings=re.findall(r'\.(\w+)\((\w+)\)',conn)
        self.assertEqual(bindings,[(p,p) for p in old])
        self.assertIn('a0_host_fragment_dual_bank_diagnostics_p114 #(',P115)
    def test_monitor_bindings_exact(self):
        pins=get_pins(MON)
        conn=P115.split('a0_frame_event_audit_p115 observer (',1)[1].split(');',1)[0]
        got=re.findall(r'\.(\w+)\((\w+)\)',conn)
        self.assertEqual([p for p,_ in got],pins)
        self.assertEqual(len(got),len(pins))
        self.assertEqual(len(set(p for p,_ in got)),len(pins))
    def test_critical_connections(self):
        for expr in ('.frame_done(frame_done)',
                     '.frame_crc_valid(frame_crc_valid)',
                     '.frame_liveness_completed(frame_liveness_completed)',
                     '.telemetry_dropped_frames(telemetry_dropped_frames)',
                     '.frame_liveness_fault(frame_liveness_fault)'):
            self.assertIn(expr,P115)
    def test_passive_no_output_gating(self):
        self.assertNotIn('assign pixel_valid',P115)
        self.assertNotIn('assign tx_valid',P115)
    def test_two_stage_agreement_in_monitor(self):
        for expr in ('!frame_done || !frame_crc_valid','frame_liveness_completed!=expected_completed_q',
                     'frame_liveness_fault','telemetry_dropped_frames!=dropped_q'):
            self.assertIn(expr,MON)
if __name__=='__main__':unittest.main()
