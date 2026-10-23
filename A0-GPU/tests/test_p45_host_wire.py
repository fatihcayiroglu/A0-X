"""P45 reference gate, *not* SystemVerilog behavior verification."""
import random
import sys
from pathlib import Path
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_host_wire_p45 import P45ReceiveSpec, ieee_crc32, parse_candidate
from a0_host_protocol_p44 import encode_command, decode_command
from a0_graphics_command_p43 import CLEAR, TRIANGLE, PRESENT, INVALID, Command

class P45SoftwareWireTests(unittest.TestCase):
    def drive(self, receiver, payload, *, stall=False):
        result=[]
        pos=0
        ticks=0
        while pos < len(payload) or receiver.pending is not None:
            if ticks > 20*len(payload)+100:
                self.fail('reference receiver stalled forever')
            ready = receiver.pending is None
            downstream_ready = not stall or (ticks % 13 == 7)
            out = receiver.tick(in_valid=pos < len(payload),
                                in_byte=payload[pos] if pos < len(payload) else 0,
                                cmd_ready=downstream_ready)
            self.assertEqual(out.in_ready, ready)
            if out.accepted_byte: pos += 1
            if out.dispatched_command: result.append(out.cmd)
            ticks += 1
        return result

    def test_crc_known_vector_and_independent_zlib(self):
        self.assertEqual(ieee_crc32(b'123456789'),0xcbf43926)
        rng=random.Random(45)
        for length in (0,1,4,28,32,256):
            for _ in range(15):
                data=rng.randbytes(length)
                self.assertEqual(ieee_crc32(data), zlib.crc32(data))

    def test_parse_exact_wire_protocol_all_operations(self):
        rows=[Command(CLEAR,0,0x123456),
              Command(TRIANGLE,1,0xfefefe,(-32768,32767,-12,42,1,-1)),
              Command(PRESENT,65535), Command(INVALID,55)]
        for row in rows:
            frame=encode_command(row)
            self.assertEqual(parse_candidate(frame),decode_command(frame))
            self.assertEqual(self.drive(P45ReceiveSpec(),frame),[row])

    def test_randomized_canonical_frames_and_fragmented_stream(self):
        rng=random.Random(451)
        commands=[]
        for tag in range(100):
            opcode = rng.randrange(4)
            color = rng.randrange(1<<24) if opcode <= 1 else 0
            coords = tuple(rng.randrange(-32768,32768) for _ in range(6)) if opcode == TRIANGLE else (0,)*6
            commands.append(Command(opcode,tag,color,coords))
        blob=b''.join(encode_command(cmd) for cmd in commands)
        self.assertEqual(self.drive(P45ReceiveSpec(),blob,stall=True),commands)

    def test_invalid_frames_discard_and_resync(self):
        valid=Command(TRIANGLE,901,0xabcdef,(1,2,3,4,5,6))
        frame=encode_command(valid)
        bad=bytearray(encode_command(Command(CLEAR,88,0x123456))); bad[-1]^=1
        receiver=P45ReceiveSpec()
        stream=b'garbage'+bytes(bad)+b'a0gc'+frame
        self.assertEqual(self.drive(receiver,stream),[valid])
        self.assertEqual(receiver.invalid_frame_count,1)

    def test_resync_magic_embedded_in_corrupted_candidate(self):
        # First corrupted 32-byte window contains an interior A0GC header.
        # The 32-byte sliding window recovers the next good frame exactly.
        packet=encode_command(Command(CLEAR,0x1234,0x112233))
        fake=b'A0GC'+b'?'*9+packet
        r=P45ReceiveSpec()
        self.assertEqual(self.drive(r,fake),[Command(CLEAR,0x1234,0x112233)])
        self.assertEqual(r.invalid_frame_count,1)

    def test_payload_canonical_checks_with_recomputed_crc(self):
        frame=encode_command(Command(PRESENT,33))
        for pos,value in ((4,2),(5,255),(11,1),(12,1),(24,1),(8,1)):
            altered=bytearray(frame)
            altered[pos]=value
            altered[28:]=ieee_crc32(altered[:28]).to_bytes(4,'little')
            self.assertIsNone(parse_candidate(bytes(altered)))
            receiver=P45ReceiveSpec()
            self.assertEqual(self.drive(receiver,bytes(altered)),[])
            self.assertEqual(receiver.invalid_frame_count,1)

    def test_backpressure_stability_and_input_refusal(self):
        row=Command(CLEAR,75,0xbeef01)
        receiver=P45ReceiveSpec()
        for byte in encode_command(row):
            receiver.tick(in_valid=True,in_byte=byte)
        self.assertEqual(receiver.pending,row)
        count=receiver.accepted
        for _ in range(100):
            result=receiver.tick(in_valid=True,in_byte=123,cmd_ready=False)
            self.assertFalse(result.in_ready)
            self.assertTrue(result.cmd_valid)
            self.assertEqual(result.cmd,row)
        self.assertEqual(receiver.accepted,count)
        response=receiver.tick(cmd_ready=True)
        self.assertTrue(response.dispatched_command)
        self.assertEqual(receiver.pending,None)
        self.assertEqual(self.drive(receiver,encode_command(Command(PRESENT,76))),[Command(PRESENT,76)])

    def test_reset_cancels_partial_and_pending(self):
        row=Command(CLEAR,12,0x123abc)
        p=encode_command(row)
        receiver=P45ReceiveSpec()
        for byte in p[:25]: receiver.tick(in_valid=True,in_byte=byte)
        receiver.tick(rst_n=False)
        self.assertEqual(self.drive(receiver,p[25:]),[])
        self.assertEqual(self.drive(receiver,p),[row])
        self.drive(receiver,p)
        receiver.tick(rst_n=False)
        self.assertEqual(receiver.dispatched,[])
        self.assertEqual(receiver.accepted,0)

    def test_partial_packet_never_dispatches(self):
        row=Command(TRIANGLE,99,0xabcdef,(1,2,3,4,5,6))
        r=P45ReceiveSpec()
        for byte in encode_command(row)[:31]:
            r.tick(in_valid=True,in_byte=byte,cmd_ready=True)
        self.assertEqual(r.pending,None)
        self.assertEqual(r.dispatched,[])

    def test_error_counter_saturates(self):
        packet=bytearray(encode_command(Command(CLEAR,3,0)))
        packet[-1]^=1
        r=P45ReceiveSpec()
        r.invalid_frame_count=0xffffffff
        self.drive(r,bytes(packet))
        self.assertEqual(r.invalid_frame_count,0xffffffff)

if __name__ == '__main__':unittest.main()
