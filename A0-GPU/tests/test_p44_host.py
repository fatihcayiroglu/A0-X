"""P44 host protocol and P43 simulation-only transport checks."""
import copy
import io
import json
import random
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stdout, redirect_stderr
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from a0_graphics_command_p43 import Command, CLEAR, TRIANGLE, PRESENT, INVALID
from a0_host_protocol_p44 import (ProtocolError, COMMAND_FRAME, RESULT_FRAME,
    SUCCESS, COMMAND_ERROR, TIMEOUT, CommandStreamDecoder, Result,
    encode_command, decode_command, encode_result, decode_result)
from a0_host_runtime_p44 import P44SoftwareDevice, png_rgb
from a0_host_p44 import parse_script, replay, load_script, main

class P44HostProtocolTests(unittest.TestCase):
    def test_abi_lengths_and_byte_layout(self):
        f=encode_command(Command(TRIANGLE, 0x1234, 0x112233, (-1,2,3,4,5,6)))
        self.assertEqual(len(f),32)
        self.assertEqual(f[:8],b'A0GC\x01\x01\x34\x12')
        self.assertEqual(f[8:12],b'\x33\x22\x11\x00')
        self.assertEqual(f[12:14],b'\xff\xff')
        self.assertEqual(decode_command(f),Command(TRIANGLE,0x1234,0x112233,(-1,2,3,4,5,6)))

    def test_command_round_trip_randomized(self):
        rng=random.Random(440)
        for _ in range(300):
            op=rng.choice((CLEAR,TRIANGLE,PRESENT,INVALID))
            c=Command(op,rng.randrange(65536), rng.randrange(1<<24) if op in (CLEAR,TRIANGLE) else 0,
                      tuple(rng.randint(-32768,32767) for _ in range(6)) if op==TRIANGLE else (0,)*6)
            self.assertEqual(decode_command(encode_command(c)),c)

    def test_reject_invalid_ranges_and_bool(self):
        bad=[Command(CLEAR,-1),Command(CLEAR,65536),Command(CLEAR,1,0x1000000),
             Command(CLEAR,1,True),Command(4,1),Command(TRIANGLE,1,vertices=(32768,)*6),
             Command(CLEAR,1,vertices=(1,)*6),Command(PRESENT,1,1)]
        for c in bad:
            with self.subTest(c=c),self.assertRaises(ProtocolError): encode_command(c)

    def test_corrupt_crc_magic_version_reserved(self):
        orig=encode_command(Command(CLEAR,3,0xabcdef))
        versions=[]
        for idx in (0,4,8,24,28):
            corrupt=bytearray(orig);corrupt[idx]^=1;versions.append(bytes(corrupt))
        for packet in versions:
            with self.subTest(packet=packet[:8]),self.assertRaises(ProtocolError): decode_command(packet)
        self.assertEqual(decode_command(orig).tag,3)

    def test_noncanonical_reserved_rejected_even_with_new_crc(self):
        from a0_host_protocol_p44 import _crc
        head=bytearray(encode_command(Command(CLEAR,7,0))[:28]);head[24]=1
        with self.assertRaisesRegex(ProtocolError,'reserved'):
            decode_command(bytes(head)+_crc(head))

    def test_invalid_payload_rejected_even_with_valid_crc(self):
        from a0_host_protocol_p44 import _crc
        head=bytearray(encode_command(Command(PRESENT,7))[:28]);head[8]=1
        with self.assertRaisesRegex(ProtocolError,'PRESENT'):
            decode_command(bytes(head)+_crc(head))

    def test_incremental_chunking_and_resync(self):
        frames=[encode_command(Command(CLEAR,i,i)) for i in range(7)]
        bad=bytearray(frames[0]);bad[10]^=1
        blob=b'garbage'+frames[0]+bytes(bad)+b'bad'+b''.join(frames[1:])
        d=CommandStreamDecoder();outs=[]
        for j in range(0,len(blob),3): outs.extend(d.feed(blob[j:j+3]))
        self.assertEqual([c.tag for c in outs],list(range(7)))
        self.assertEqual(d.invalid_frames,1)
        self.assertGreater(d.dropped_bytes,0)

    def test_no_acceptance_from_truncated_frame(self):
        d=CommandStreamDecoder();f=encode_command(Command(CLEAR,8))
        self.assertEqual(d.feed(f[:-1]),[])
        self.assertEqual([c.tag for c in d.feed(f[-1:])],[8])

    def test_result_round_trip_crc(self):
        for status in (SUCCESS,COMMAND_ERROR,TIMEOUT):
            r=Result(status,65535,987654)
            f=encode_result(r)
            self.assertEqual(len(f),RESULT_FRAME)
            self.assertEqual(decode_result(f),r)
            bad=bytearray(f);bad[-1]^=1
            with self.assertRaises(ProtocolError):decode_result(bytes(bad))
        with self.assertRaises(ProtocolError):encode_result(Result(3,4,5))

    def test_boolean_and_unknown_bytes_stream_rejected(self):
        d=CommandStreamDecoder()
        with self.assertRaises(TypeError):d.feed('str')
        self.assertEqual(d.feed(b'\0'*1024),[])
        self.assertLessEqual(len(d.buffer),3)

class P44SoftwareDeviceTests(unittest.TestCase):
    def test_real_tagged_sequence_via_binary_transport(self):
        d=P44SoftwareDevice(8,8)
        cs=[Command(CLEAR,101,0x121212),Command(TRIANGLE,102,0xff0000,(0,0,7,0,0,7)),Command(PRESENT,103)]
        result=b''.join(d.receive(encode_command(c)) for c in cs)
        replies=[decode_result(result[i:i+16]) for i in range(0,len(result),16)]
        self.assertEqual([r.tag for r in replies],[101,102,103])
        self.assertTrue(all(r.ok for r in replies))
        self.assertEqual(len(d.visible_rgb()),8*8*3)
        self.assertEqual(len(d.image_digest()),64)

    def test_invalid_op_error_and_no_present(self):
        d=P44SoftwareDevice(3,3)
        self.assertEqual(decode_result(d.receive(encode_command(Command(INVALID,4)))).status,COMMAND_ERROR)
        self.assertEqual(decode_result(d.receive(encode_command(Command(PRESENT,5)))).status,COMMAND_ERROR)
        with self.assertRaises(RuntimeError):d.visible_rgb()

    def test_bad_crc_no_side_effects(self):
        d=P44SoftwareDevice(2,2)
        f=bytearray(encode_command(Command(CLEAR,2,0xaabbcc)));f[-1]^=1
        self.assertEqual(d.receive(bytes(f)),b'')
        self.assertFalse(d.adapter.display.render_initialized)
        self.assertEqual(d.decoder.invalid_frames,1)

    def test_cycle_deadline_fail_closed(self):
        d=P44SoftwareDevice(8,8,max_cycles=2)
        r=decode_result(d.receive(encode_command(Command(CLEAR,6,0))))
        self.assertEqual(r.status,TIMEOUT)
        with self.assertRaises(RuntimeError):d.receive(encode_command(Command(CLEAR,7)))

    def test_png_standardlibrary_round_trip_header(self):
        import zlib
        png=png_rgb(2,1,b'\xff\0\0\0\xff\0')
        self.assertEqual(png[:8],b'\x89PNG\r\n\x1a\n')
        self.assertEqual(png[12:16],b'IHDR')
        self.assertEqual(struct.unpack('>II',png[16:24]),(2,1))
        start=8+25
        n=struct.unpack('>I',png[start:start+4])[0]
        self.assertEqual(zlib.decompress(png[start+8:start+8+n]),b'\0\xff\0\0\0\xff\0')

    def test_reject_resolution_limits(self):
        for w,h in ((0,8),(1,0),(32768,1),(300,300),('8',8),(True,8)):
            with self.subTest(w=w,h=h),self.assertRaises(ValueError):P44SoftwareDevice(w,h)

class P44ScriptTests(unittest.TestCase):
    def setUp(self):
        self.good={'width':8,'height':8,'commands':[
            {'op':'CLEAR','tag':1,'color':'#112233'},
            {'op':'TRIANGLE','tag':2,'color':0xffaa00,'vertices':[[0,0],[7,0],[0,7]]},
            {'op':'PRESENT','tag':3}]}

    def test_replay_fragment_sizes(self):
        digest=None
        for k in (1,2,3,7,32,64):
            result,rgb=replay(self.good,fragment_size=k)
            self.assertTrue(all(c['status']=='OK' for c in result['commands']))
            self.assertEqual([c['tag'] for c in result['commands']],[1,2,3])
            self.assertEqual(len(rgb),8*8*3)
            if digest is None:digest=result['rgb_sha256']
            self.assertEqual(result['rgb_sha256'],digest)

    def test_p43_reference_demo_exact_compatibility(self):
        from p43_render_demo import draw
        base, _=draw(width=96,height=64)
        example=Path(__file__).resolve().parents[1]/'examples/p44_triangle.json'
        report,rgb=replay(json.loads(example.read_text()),fragment_size=5)
        self.assertEqual(rgb,b''.join(int(x).to_bytes(3,'big') for x in base))
        self.assertEqual(report['commands_completed'],5)

    def test_randomized_incremental_transport_vs_batch(self):
        rng=random.Random(449)
        commands=[Command(CLEAR,tag,rng.randrange(1<<24)) for tag in range(1,20)]
        commands+=[Command(PRESENT,30)]
        frames=b''.join(encode_command(c) for c in commands)
        d=P44SoftwareDevice(3,3)
        response=bytearray()
        i=0
        while i<len(frames):
            sz=rng.randint(1,47)
            response.extend(d.receive(frames[i:i+sz]));i+=sz
        receipts=[decode_result(response[i:i+16]) for i in range(0,len(response),16)]
        self.assertEqual([r.tag for r in receipts],[c.tag for c in commands])
        self.assertTrue(all(r.ok for r in receipts))

    def test_deterministic_reference_pixel_data(self):
        from a0_triangle_coverage_p38 import Triangle, rasterize
        _,rgb=replay(self.good)
        covered=set(rasterize(Triangle((0,0),(7,0),(0,7)),8,8))
        cells=[int.from_bytes(rgb[i:i+3],'big') for i in range(0,len(rgb),3)]
        self.assertEqual(cells,[0xffaa00 if (i%8,i//8) in covered else 0x112233 for i in range(64)])

    def test_malformed_scripts_fail_before_effects(self):
        bads=[{'width':True,'height':8,'commands':self.good['commands']},
              {'width':8,'height':8,'commands':[{'op':'CLEAR','tag':1,'color':'#GGFF00'}]},
              {'width':8,'height':8,'commands':[{'op':'CLEAR','tag':-1,'color':0}]},
              {'width':8,'height':8,'commands':[{'op':'TRIANGLE','tag':1,'color':0,'vertices':[[0,0],[1,1]]}]},
              {'width':8,'height':8,'commands':[{'op':'PRESENT','tag':1,'color':0}]},
              {'width':8,'height':8,'commands':[{'op':'PRESENT','tag':1},{'op':'INVALID','tag':1}]},
              {'width':8,'height':8,'commands':[{'op':'UNKNOWN','tag':1}]},
              {'width':257,'height':256,'commands':[{'op':'PRESENT','tag':1}]}]
        for obj in bads:
            with self.subTest(obj=obj),self.assertRaises(ProtocolError):parse_script(obj)

    def test_replay_bootstrap_error(self):
        obj={'width':2,'height':2,'commands':[{'op':'TRIANGLE','tag':1,'color':0,'vertices':[[0,0],[1,0],[0,1]]}]}
        report,rgb=replay(obj)
        self.assertEqual(report['commands'][0]['status'],'COMMAND_ERROR')
        self.assertIsNone(rgb)

    def test_json_duplicate_keys_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'bad.json';p.write_text('{"width":2,"width":3,"height":2,"commands":[]}',encoding='utf-8')
            with self.assertRaisesRegex(ProtocolError,'duplicate'):load_script(p)

    def test_cli_generates_png_and_receipt(self):
        with tempfile.TemporaryDirectory() as td:
            tmp=Path(td)
            script=tmp/'script.json';png=tmp/'image.png';receipt=tmp/'receipt.json'
            script.write_text(json.dumps(self.good),encoding='utf-8')
            with redirect_stdout(io.StringIO()):
                exitcode=main(['--script',str(script),'--output',str(png),'--receipt',str(receipt)])
            self.assertEqual(exitcode,0)
            self.assertTrue(png.read_bytes().startswith(b'\x89PNG'))
            self.assertEqual(json.loads(receipt.read_text())['kind'],'P44_SOFTWARE_REFERENCE_ONLY')

    def test_cli_returns_nonzero_for_failed_command(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'commands.json';p.write_text(json.dumps({'width':2,'height':2,'commands':[{'op':'PRESENT','tag':1}]}))
            with redirect_stdout(io.StringIO()):
                self.assertEqual(main(['--script',str(p)]),1)

if __name__=='__main__':unittest.main()
