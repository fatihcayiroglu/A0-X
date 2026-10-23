"""P105 new software behavior checks; no hardware simulation."""
import random
import sys
import unittest
import zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_graphics_command_p43 import CLEAR,TRIANGLE,PRESENT,INVALID,Command
from a0_host_protocol_p44 import encode_command,encode_result,Result
from a0_frame_telemetry_p48 import encode_frame,decode_host_frames
from a0_p105_host_double_bank_reference import P105HostReference,audit_capture
from a0_p105_host_dual_bank_reference import P105HostSession

ZERO=(0,)*6

def cmd(opcode, tag, color=0, vertices=ZERO):
    return Command(opcode,tag,color,vertices)

def crc_color(c,count):
    return zlib.crc32(c.to_bytes(3,'little')*count)

class TestP105HostDoubleBank(unittest.TestCase):
    def setUp(self):
        self.r=P105HostReference(4,4)
    def send(self,c,**kw):
        return self.r.send(encode_command(c),**kw)
    def test_clear_present_frame_result_and_crc(self):
        commands=[cmd(CLEAR,1,0x123456),cmd(PRESENT,2)]
        for c in commands:self.send(c)
        self.r.drain()
        records=decode_host_frames(self.r.wire_capture())
        self.assertEqual([p['kind'] for p in records],['result','result','frame'])
        self.assertEqual(audit_capture(commands,[crc_color(0x123456,16)],self.r.wire_capture())['frames'],1)
    def test_host_protocol_overwrite_not_default_depth_less(self):
        commands=[cmd(CLEAR,1,0),
            cmd(TRIANGLE,2,0xff0000,(0,0,4,0,0,4)),
            cmd(TRIANGLE,3,0x00ff00,(0,0,4,0,0,4)),cmd(PRESENT,4)]
        for c in commands:self.send(c)
        self.r.drain()
        self.assertEqual(self.r.device.banks[self.r.device.display_bank].pixel(1,1)[0],0x00ff00)
        expected=b''.join(self.r.device.banks[self.r.device.display_bank].colors[i].to_bytes(3,'little') for i in range(16))
        self.assertTrue(audit_capture(commands,[zlib.crc32(expected)],self.r.wire_capture()))
    def test_draw_next_frame_while_previous_stalls(self):
        commands=[cmd(CLEAR,1,0x111111),cmd(PRESENT,2),cmd(CLEAR,3,0x222222),cmd(PRESENT,4)]
        self.send(commands[0]);self.send(commands[1]);self.r.tick()
        for _ in range(11):self.r.tick(pixel_ready=False)
        self.send(commands[2]);self.send(commands[3]);
        with self.assertRaises(RuntimeError):self.send(cmd(CLEAR,5,0xabcdef))
        self.r.drain(ready=lambda t:t%3!=0)
        self.r.drain(ready=lambda t:t%5!=0)
        self.assertEqual([seq for seq,_ in self.r.frame_events],[0,1])
        self.assertEqual([crc for _,crc in self.r.frame_events],
                         [crc_color(0x111111,16),crc_color(0x222222,16)])
        self.assertEqual(audit_capture(commands,[crc_color(0x111111,16),crc_color(0x222222,16)],self.r.wire_capture())['frames'],2)
    def test_invalid_crc_rejected_without_side_effect(self):
        bad=bytearray(encode_command(cmd(CLEAR,8,0xabcabc)));bad[8]^=1
        with self.assertRaises(ValueError):self.r.send(bytes(bad))
        self.assertFalse(self.r.device.render_initialized)
        self.assertEqual(self.r.wire_capture(),b'')
    def test_present_requires_permission(self):
        self.send(cmd(CLEAR,1,1))
        with self.assertRaises(RuntimeError):self.send(cmd(PRESENT,2),scan_enable=False)
        self.assertIsNone(self.r.pending_tag)
        self.send(cmd(PRESENT,2));self.r.drain()
        self.assertEqual(self.r.result_events,[(1,False),(2,False)])
    def test_invalid_opcode_has_error_and_no_frame(self):
        self.send(cmd(INVALID,5))
        result,=decode_host_frames(self.r.wire_capture())
        self.assertEqual((result['tag'],result['error']),(5,True))
        self.assertEqual(self.r.frame_count,0)
    def test_triangle_before_clear_error(self):
        self.send(cmd(TRIANGLE,4,0xffffff,(0,0,4,0,0,4)))
        self.assertEqual(self.r.result_events,[(4,True)])
    def test_reset_invalidates_frame_and_counters(self):
        self.send(cmd(CLEAR,1,1));self.send(cmd(PRESENT,2));self.r.tick()
        for _ in range(3):self.r.tick()
        self.r.reset()
        self.assertEqual((self.r.frame_count,self.r.events,self.r.pending_tag),(0,[],None))
        self.assertFalse(self.r.device.render_initialized)
    def test_audit_missing_duplicate_result(self):
        cs=[cmd(CLEAR,1,0x112233),cmd(PRESENT,2)]
        for c in cs:self.send(c)
        self.r.drain()
        wire=self.r.wire_capture();expect=[crc_color(0x112233,16)]
        with self.assertRaises(ValueError):audit_capture(cs,expect,wire[16:])
        with self.assertRaises(ValueError):audit_capture(cs,expect,wire[:16]+wire)
    def test_audit_extra_or_missing_frame(self):
        cs=[cmd(CLEAR,1,0x112233),cmd(PRESENT,2)]
        for c in cs:self.send(c)
        self.r.drain()
        wire=self.r.wire_capture();expect=[crc_color(0x112233,16)]
        with self.assertRaises(ValueError):audit_capture(cs,expect,wire[:-32])
        with self.assertRaises(ValueError):audit_capture(cs,expect,wire+wire[-32:])
    def test_audit_wrong_crc_and_sequence(self):
        cs=[cmd(CLEAR,1,0x112233),cmd(PRESENT,2)]
        for c in cs:self.send(c)
        self.r.drain()
        wire=self.r.wire_capture()
        with self.assertRaises(ValueError):audit_capture(cs,[0],wire)
        forged=encode_frame(sequence=2,error=False,frame_crc=crc_color(0x112233,16),good=1,bad=0,aborted=0,dropped=0)
        with self.assertRaises(ValueError):audit_capture(cs,[crc_color(0x112233,16)],wire[:-32]+forged)
    def test_audit_noisy_truncated_and_corrupt_capture(self):
        cs=[cmd(CLEAR,1,1),cmd(PRESENT,2)]
        for c in cs:self.send(c)
        self.r.drain()
        wire=self.r.wire_capture();exp=[crc_color(1,16)]
        for bad in [b'NOISE'+wire,wire[:-1],wire+b'JUNK']:
            with self.assertRaises(ValueError):audit_capture(cs,exp,bad)
        bad=bytearray(wire);bad[-1]^=1
        with self.assertRaises(ValueError):audit_capture(cs,exp,bytes(bad))
    def test_audit_repeated_tag_rejected(self):
        cs=[cmd(CLEAR,1,1),cmd(PRESENT,1)]
        for c in cs:self.send(c)
        self.r.drain()
        with self.assertRaises(ValueError):audit_capture(cs,[crc_color(1,16)],self.r.wire_capture())
    def test_random_multiframe_golden_crc(self):
        r=random.Random(105)
        commands=[];crc=[]
        for i in range(35):
            color=r.randrange(0x1000000)
            a=cmd(CLEAR,2*i+1,color);b=cmd(PRESENT,2*i+2)
            commands.extend((a,b)); self.send(a);self.send(b)
            self.r.drain(ready=lambda t:r.randrange(4)>0)
            crc.append(crc_color(color,16))
        report=audit_capture(commands,crc,self.r.wire_capture())
        self.assertEqual(report['commands'],70)
        self.assertEqual(report['frames'],35)
    def test_two_independent_models_agree_on_wire_crc(self):
        # First model accumulates accepted pixel RGB; predecessor P105 model
        # uses its separate P47 frame-integrity observer. Compare outputs.
        predecessor=P105HostSession(4,4)
        commands=[cmd(CLEAR,1,0x010203),cmd(PRESENT,2),
                  cmd(CLEAR,3,0x445566),cmd(PRESENT,4)]
        self.send(commands[0]);self.send(commands[1]);self.r.drain()
        self.send(commands[2]);self.send(commands[3]);self.r.drain()
        for command in commands:
            predecessor.issue(encode_command(command))
        predecessor.drain()
        frames=decode_host_frames(b''.join(predecessor.telemetry))
        self.assertEqual([p['frame_crc'] for p in frames],
                         [crc for _,crc in self.r.frame_events])
        self.assertEqual([p['sequence'] for p in frames],[0,1])
        self.assertEqual([x[0] for x in self.r.result_events],
                         [p['tag'] for p in decode_host_frames(b''.join(predecessor.results))])

    def test_source_integrates_actual_p104_not_legacy_target(self):
        s=(Path(__file__).resolve().parents[1]/'rtl/graphics/a0_host_dual_bank_telemetry_bridge_p105.sv').read_text()
        for name in ('a0_host_command_rx_p45','a0_command_dual_bank_scanout_p104',
                     'a0_scanout_frame_guard_p47','a0_host_result_tx_p46',
                     'a0_scanout_telemetry_tx_p48','a0_host_tx_fair_arbiter_p49',
                     '.stream_active(scan_active)','.cmd_depth_op(2\'d0)',
                     '.cmd_depth_write(1\'b0)'):
            self.assertIn(name,s)
        self.assertNotIn('a0_command_triangle_sync_display_p43 #',s)

if __name__=='__main__':unittest.main()
