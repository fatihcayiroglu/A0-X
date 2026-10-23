"""P46 software spec tests, NOT RTL test results."""
import random
import sys
import unittest
import zlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from a0_host_result_wire_p46 import P46TransmitSpec, serialize_result, wire_crc32
from a0_host_protocol_p44 import (encode_result, decode_result, Result,
                                  SUCCESS, COMMAND_ERROR, ProtocolError)


class P46SoftwareReferenceTests(unittest.TestCase):
    def drain(self, tx, *, seed=46):
        rng = random.Random(seed)
        payload = bytearray()
        steps = 0
        while steps < 10000:
            ready = rng.randrange(4) == 0
            r = tx.tick(out_ready=ready)
            if r.emitted_byte:
                payload.append(r.out_byte)
            if not r.out_valid:
                break
            steps += 1
        else:
            self.fail('TX stalled')
        return bytes(payload)

    def test_ieee_crc_reference_vector(self):
        self.assertEqual(wire_crc32(b'123456789'), 0xcbf43926)
        rng = random.Random(466)
        for size in [0, 1, 3, 12, 28, 256]:
            for _ in range(12):
                vector = rng.randbytes(size)
                self.assertEqual(wire_crc32(vector), zlib.crc32(vector))

    def test_serialization_matches_frozen_p44_both_statuses(self):
        for error in (False, True):
            for tag in (0, 1, 0x1234, 0xffff):
                for cycles in (0, 1, 0x10203040, 0xffffffff):
                    expected = encode_result(Result(COMMAND_ERROR if error else SUCCESS, tag, cycles))
                    self.assertEqual(serialize_result(tag, error, cycles), expected)
                    self.assertEqual(decode_result(expected).tag, tag)

    def test_randomized_vectors_match_p44(self):
        rng = random.Random(4600)
        for _ in range(500):
            tag, cycles = rng.randrange(65536), rng.randrange(1 << 32)
            error = bool(rng.randrange(2))
            expected = encode_result(Result(int(error), tag, cycles))
            self.assertEqual(serialize_result(tag, error, cycles), expected)

    def test_valid_16_byte_frame_under_stalls(self):
        tx = P46TransmitSpec()
        r = tx.tick(result_valid=True, tag=0x1234, error=False, cycles=0x90abcdef)
        self.assertTrue(r.accepted_result)
        self.assertFalse(r.out_valid)
        expected = encode_result(Result(SUCCESS, 0x1234, 0x90abcdef))
        self.assertEqual(self.drain(tx), expected)
        self.assertEqual(tx.accepted_results, 1)
        self.assertEqual(tx.emitted_bytes, 16)
        self.assertTrue(tx.tick().result_ready)

    def test_payload_stable_under_100_cycle_backpressure(self):
        tx = P46TransmitSpec()
        tx.tick(result_valid=True, tag=17, cycles=0x12345678)
        for _ in range(100):
            r = tx.tick(result_valid=True, tag=92, error=True, cycles=0, out_ready=False)
            self.assertTrue(r.out_valid)
            self.assertFalse(r.result_ready)
            self.assertFalse(r.accepted_result)
            self.assertEqual(r.out_byte, ord('A'))
        self.assertEqual(self.drain(tx, seed=50), encode_result(Result(SUCCESS, 17, 0x12345678)))
        self.assertEqual(tx.accepted_results, 1)

    def test_second_input_requires_release_after_16th_byte(self):
        tx = P46TransmitSpec()
        tx.tick(result_valid=True, tag=1)
        for _ in range(15):
            self.assertFalse(tx.tick(result_valid=True, tag=2, out_ready=True).accepted_result)
        last = tx.tick(result_valid=True, tag=2, out_ready=True)
        self.assertTrue(last.out_valid)
        self.assertFalse(last.accepted_result)
        self.assertTrue(tx.tick(result_valid=True, tag=2, error=True).accepted_result)
        self.assertEqual(self.drain(tx), encode_result(Result(COMMAND_ERROR, 2, 0)))

    def test_reset_discards_untransmitted_payload(self):
        tx = P46TransmitSpec()
        tx.tick(result_valid=True, tag=999)
        for _ in range(6): tx.tick(out_ready=True)
        reset = tx.tick(rst_n=False)
        self.assertFalse(reset.result_ready)
        self.assertFalse(reset.out_valid)
        self.assertEqual(tx.emitted_bytes, 0)
        self.assertTrue(tx.tick().result_ready)
        tx.tick(result_valid=True, tag=32, error=True, cycles=42)
        self.assertEqual(self.drain(tx), encode_result(Result(COMMAND_ERROR, 32, 42)))

    def test_100_back_to_back_transactions_with_arbitrary_stalls(self):
        rng = random.Random(462)
        tx = P46TransmitSpec()
        for tag in range(100):
            error = bool(tag % 2)
            cycles = rng.randrange(1 << 32)
            self.assertTrue(tx.tick(result_valid=True, tag=tag, error=error, cycles=cycles).accepted_result)
            self.assertEqual(self.drain(tx, seed=tag+2),encode_result(Result(int(error), tag, cycles)))
        self.assertEqual(tx.accepted_results, 100)
        self.assertEqual(tx.emitted_bytes, 1600)

    def test_invalid_fields_are_rejected_by_reference(self):
        for tag, error, cycles in ((-1,False,0),(65536,False,0),(True,False,0),
                                   (2,1,0),(2,False,-1),(2,False,1<<32),
                                   (2,False,True)):
            with self.subTest(tag=tag,error=error,cycles=cycles):
                with self.assertRaises(ValueError): serialize_result(tag,error,cycles)

    def test_result_crc_corruption_is_detected(self):
        f = serialize_result(0xabcd,True,0x11223344)
        self.assertEqual(f[0:4],b'A0GR')
        self.assertEqual(f[6:8],b'\xcd\xab')
        for index in (0,4,5,7,8,11,12,15):
            bad=bytearray(f);bad[index]^=0x80
            with self.subTest(index=index),self.assertRaises(ProtocolError): decode_result(bytes(bad))

if __name__=='__main__': unittest.main()
