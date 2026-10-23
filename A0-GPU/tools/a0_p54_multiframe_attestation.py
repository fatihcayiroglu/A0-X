#!/usr/bin/env python3
"""P54 multi-PRESENT software-reference-vs-supplied-byte capture checker.

It DOES NOT prove that a capture came from RTL, FPGA or physical hardware.
An external and independently established provenance chain is required.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
sys.path.insert(0, str(ROOT / 'tools'))
from a0_host_p44 import load_script, parse_script
from a0_host_runtime_p44 import P44SoftwareDevice
from a0_host_protocol_p44 import decode_result, encode_command, SUCCESS
from a0_graphics_command_p43 import PRESENT
from a0_frame_integrity_p47 import expected_crc
from a0_host_result_wire_p46 import serialize_result
from a0_frame_telemetry_p48 import encode_frame
from a0_host_stream_p49 import HostStreamDecoder

MAX_COMMANDS = 256
MAX_FRAMES = 256
MAX_CAPTURE_BYTES = 16 * 1024 * 1024


def reference(script: dict) -> dict:
    width, height, commands = parse_script(script)
    if len(commands) > MAX_COMMANDS:
        raise ValueError('P54 permits at most 256 commands')
    if commands[-1][1].opcode != PRESENT:
        raise ValueError('P54 requires a final PRESENT')
    device = P44SoftwareDevice(width, height)
    results, frames = [], []
    for op, command in commands:
        result_wire = device.receive(encode_command(command))
        if len(result_wire) != 16:
            raise ValueError('reference did not return exactly one result packet')
        reply = decode_result(result_wire)
        if reply.status != SUCCESS or reply.tag != command.tag:
            raise ValueError('P54 requires all reference commands to succeed')
        results.append({'tag':reply.tag,'op':op})
        if command.opcode == PRESENT:
            rgb = device.visible_rgb()
            pixels = [int.from_bytes(rgb[i:i+3],'big') for i in range(0,len(rgb),3)]
            frames.append({'present_tag':command.tag,
                           'after_result_index':len(results),
                           'frame_crc32':expected_crc(pixels),
                           'rgb_sha256':hashlib.sha256(rgb).hexdigest()})
            if len(frames) > MAX_FRAMES:
                raise ValueError('P54 permits at most 256 frames')
    if len(frames) < 2:
        raise ValueError('P54 requires at least two PRESENT commands; use P53 for single-shot')
    return {'width':width,'height':height,'results':results,'frames':frames}


def synthetic_fixture(ref: dict) -> bytes:
    """For self tests only: never represent this as an actual device capture."""
    out = bytearray()
    frames_by_position = {f['after_result_index']: (i,f) for i,f in enumerate(ref['frames'])}
    for index, result in enumerate(ref['results'],1):
        out.extend(serialize_result(result['tag'], False, 123))
        if index in frames_by_position:
            i, frame = frames_by_position[index]
            out.extend(encode_frame(sequence=i,error=False,
                                    frame_crc=frame['frame_crc32'],
                                    good=i+1,bad=0,aborted=0,dropped=0))
    return bytes(out)


def attest(script: dict, capture: bytes, *, chunk_size=7) -> dict:
    if type(capture) is not bytes or len(capture) > MAX_CAPTURE_BYTES:
        raise ValueError('capture must be bytes no larger than 16 MiB')
    if type(chunk_size) is not int or not 1 <= chunk_size <= MAX_CAPTURE_BYTES:
        raise ValueError('chunk_size must be an integer 1..16 MiB')
    ref = reference(script)
    decoder = HostStreamDecoder()
    results, frames, failures = [], [], []
    for start in range(0,len(capture),chunk_size):
        for record in decoder.feed(capture[start:start+chunk_size]):
            if record['kind']=='result':
                results.append(record)
            else:
                frame_index=len(frames)
                if frame_index < len(ref['frames']) and len(results) < ref['frames'][frame_index]['after_result_index']:
                    failures.append(f'frame_before_present_completion_{frame_index}')
                frames.append(record)
    decoded = decoder.finish()
    if any(decoded[key] for key in ('invalid_candidates','discarded_bytes','incomplete_tail_bytes')):
        failures.append('invalid_or_truncated_capture')
    if len(results)!=len(ref['results']):
        failures.append('completion_count_mismatch')
    if len(frames)!=len(ref['frames']):
        failures.append('frame_count_mismatch')
    for index, (actual,expected) in enumerate(zip(results,ref['results'])):
        if actual['tag']!=expected['tag']:
            failures.append(f'completion_tag_mismatch_{index}')
        if actual['error']:
            failures.append(f'completion_error_{index}')
    for index, (actual,expected) in enumerate(zip(frames,ref['frames'])):
        if actual['sequence']!=index:
            failures.append(f'frame_sequence_mismatch_{index}')
        if actual['good']!=index+1:
            failures.append(f'frame_good_counter_mismatch_{index}')
        if actual['error'] or actual['bad']!=0 or actual['aborted']!=0 or actual['dropped']!=0:
            failures.append(f'frame_error_or_loss_{index}')
        if actual['frame_crc']!=expected['frame_crc32']:
            failures.append(f'frame_crc_mismatch_{index}')
    return {'kind':'A0_P54_MULTIFRAME_SOFTWARE_CAPTURE_CHECK',
            'evidence_level':'SOFTWARE_REFERENCE_VS_SUPPLIED_BYTES_NOT_RTL_OR_HARDWARE',
            'status':'PASS' if not failures else 'FAIL',
            'failures':sorted(set(failures)),
            'reference':ref,
            'observed':{'results':len(results),'frames':len(frames),
                        'capture_sha256':hashlib.sha256(capture).hexdigest(),
                        'decoder':decoded}}


def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--script', type=Path, required=True)
    group=ap.add_mutually_exclusive_group(required=True)
    group.add_argument('--capture',type=Path)
    group.add_argument('--make-synthetic-fixture',type=Path)
    ap.add_argument('--report',type=Path)
    args=ap.parse_args(argv)
    try:
        script=load_script(args.script)
        if args.make_synthetic_fixture is not None:
            ref=reference(script)
            args.make_synthetic_fixture.parent.mkdir(parents=True,exist_ok=True)
            args.make_synthetic_fixture.write_bytes(synthetic_fixture(ref))
            report={'kind':'A0_P54_SYNTHETIC_SOFTWARE_FIXTURE',
                    'evidence_level':'SOFTWARE_ONLY_NOT_DEVICE_EVIDENCE',
                    'reference':ref,'output':str(args.make_synthetic_fixture)}
        else:
            if args.capture.stat().st_size > MAX_CAPTURE_BYTES:
                raise ValueError('capture larger than 16 MiB')
            report=attest(script,args.capture.read_bytes())
        doc=json.dumps(report,sort_keys=True,indent=2)+'\n'
        if args.report:
            args.report.parent.mkdir(parents=True,exist_ok=True)
            args.report.write_text(doc,encoding='utf-8')
        else:
            print(doc,end='')
        return 1 if report.get('status')=='FAIL' else 0
    except (OSError,ValueError,RuntimeError) as exc:
        print(f'P54 ERROR: {exc}',file=sys.stderr)
        return 2

if __name__=='__main__':
    sys.exit(main())
