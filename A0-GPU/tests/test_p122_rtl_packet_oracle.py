"""P122 packet software model tests. These are NEVER HDL/FPGA execution."""
import importlib.util
import json
from pathlib import Path
import struct
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

oracle=load('p122_oracle',ROOT/'tools/a0_p122_packet_oracle.py')

class PacketOracle(unittest.TestCase):
    def test_frame_packet_exact_size(self):
        self.assertEqual(len(oracle.frame(sequence=0,frame_crc=0)),32)

    def test_loss_packet_exact_size(self):
        self.assertEqual(len(oracle.loss_notice(sequence=0,dropped=1)),32)

    def test_frame_field_mapping(self):
        p=oracle.frame(sequence=65535,frame_crc=0x12345678,error=True,
                       good=1,bad=2,aborted=3,dropped=4)
        self.assertEqual(p[:4],b'A0GF')
        self.assertEqual(p[4:8],b'\x01\x01\xff\xff')
        self.assertEqual(struct.unpack('<IIIII',p[8:28]),
                         (0x12345678,1,2,3,4))

    def test_loss_field_mapping(self):
        p=oracle.loss_notice(sequence=3,dropped=1,good=4,bad=5,aborted=6)
        self.assertEqual(p[:4],b'A0GL')
        self.assertEqual(p[4:8],b'\x01\x01\x03\x00')
        self.assertEqual(struct.unpack('<IIIII',p[8:28]),(1,4,5,6,0))

    def test_wire_crc_28_bytes_both_packet_types(self):
        for p in [oracle.frame(sequence=5,frame_crc=10),
                  oracle.loss_notice(sequence=6,dropped=77)]:
            self.assertEqual(struct.unpack('<I',p[28:])[0],zlib.crc32(p[:28]))

    def test_decode_frame_roundtrip(self):
        p=oracle.frame(sequence=42,frame_crc=0xAABBCCDD,error=False,
                       good=1,bad=4,aborted=9,dropped=7)
        self.assertEqual(oracle.decode(p),{'type':'frame','sequence':42,
            'error':False,'frame_crc':0xAABBCCDD,'good':1,'bad':4,'aborted':9,'dropped':7})

    def test_decode_loss_roundtrip(self):
        p=oracle.loss_notice(sequence=9,dropped=2,good=5,bad=1,aborted=3)
        self.assertEqual(oracle.decode(p),{'type':'loss','sequence':9,
            'dropped':2,'good':5,'bad':1,'aborted':3})

    def test_mutated_payload_rejected(self):
        p=bytearray(oracle.frame(sequence=1,frame_crc=2));p[8]^=0x10
        with self.assertRaisesRegex(ValueError,'CRC32'):
            oracle.decode(bytes(p))

    def test_mutated_crc_rejected(self):
        p=bytearray(oracle.loss_notice(sequence=2,dropped=1));p[31]^=0xFF
        with self.assertRaisesRegex(ValueError,'CRC32'):
            oracle.decode(bytes(p))

    def test_wrong_size_rejected(self):
        with self.assertRaises(ValueError):oracle.decode(b'')
        with self.assertRaises(ValueError):oracle.decode(bytes(33))

    def test_unknown_magic_rejected_even_with_valid_crc(self):
        p=bytearray(oracle.loss_notice(sequence=0,dropped=1));p[0]=ord('Z')
        p[28:]=struct.pack('<I',zlib.crc32(p[:28]))
        with self.assertRaisesRegex(ValueError,'invalid packet'):
            oracle.decode(bytes(p))

    def test_reserved_loss_field_must_be_zero(self):
        p=bytearray(oracle.loss_notice(sequence=3,dropped=4))
        p[24]=1;p[28:]=struct.pack('<I',zlib.crc32(p[:28]))
        with self.assertRaisesRegex(ValueError,'invalid packet'):
            oracle.decode(bytes(p))

    def test_invalid_version_rejected_even_with_crc(self):
        p=bytearray(oracle.frame(sequence=0,frame_crc=2));p[4]=2
        p[28:]=struct.pack('<I',zlib.crc32(p[:28]))
        with self.assertRaisesRegex(ValueError,'version'):
            oracle.decode(bytes(p))

    def test_invalid_32bit_number_rejected(self):
        with self.assertRaises(ValueError):oracle.frame(sequence=0,frame_crc=2**32)
        with self.assertRaises(ValueError):oracle.loss_notice(sequence=2**16,dropped=0)
        with self.assertRaises(ValueError):oracle.loss_notice(sequence=1,dropped=-1)

    def test_boolean_rejected_as_integer(self):
        with self.assertRaises(ValueError):oracle.loss_notice(sequence=True,dropped=0)

    def test_error_not_bool_rejected(self):
        with self.assertRaises(ValueError):oracle.frame(sequence=0,frame_crc=0,error=1)

    def test_sequence_wrap_must_be_explicit(self):
        with self.assertRaises(ValueError):oracle.frame(sequence=65536,frame_crc=0)
        self.assertEqual(oracle.decode(oracle.frame(sequence=0,frame_crc=1))['sequence'],0)

if __name__=='__main__':unittest.main()
