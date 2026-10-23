#!/usr/bin/env python3
"""P52: compare a P44 one-PRESENT script with an independently captured host stream.

The expected rendered image comes from P43/P44 *software only*. This does not
prove RTL, a physical display, or a genuine GPU; an external capture's origin
must be established separately. The acceptance contract is intentionally a
single, quiescent, single-shot frame capture (exactly one final PRESENT).
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
from a0_host_protocol_p44 import encode_command, decode_result, SUCCESS, TIMEOUT
from a0_graphics_command_p43 import PRESENT
from a0_frame_integrity_p47 import expected_crc
from a0_host_stream_p49 import HostStreamDecoder, FrameSequenceAudit
from a0_host_result_wire_p46 import serialize_result
from a0_frame_telemetry_p48 import encode_frame

MAX_COMMANDS = 256
MAX_CAPTURE_BYTES = 16 * 1024 * 1024


def reference(script: dict) -> dict:
    width, height, commands = parse_script(script)
    if len(commands) > MAX_COMMANDS:
        raise ValueError('P52 bound: maximum 256 commands')
    if commands[-1][1].opcode != PRESENT or sum(c.opcode == PRESENT for _,c in commands) != 1:
        raise ValueError('P52 single-shot contract requires one final PRESENT')
    device = P44SoftwareDevice(width, height)
    expected = []
    for op, command in commands:
        wire = device.receive(encode_command(command))
        if len(wire) != 16:
            raise ValueError('software device failed to produce one completion')
        reply = decode_result(wire)
        if reply.status == TIMEOUT or reply.tag != command.tag:
            raise ValueError('reference timed out or tag conservation failed')
        expected.append({'tag':reply.tag, 'error':reply.status != SUCCESS, 'op':op})
    if expected[-1]['error']:
        raise ValueError('PRESENT did not succeed in reference')
    rgb = device.visible_rgb()  # P44 display stores RGB888 in big-endian bytes
    colors = [int.from_bytes(rgb[i:i+3], 'big') for i in range(0, len(rgb), 3)]
    return {'width':width, 'height':height, 'results':expected,
            'frame_crc32':expected_crc(colors),
            'rgb_sha256':hashlib.sha256(rgb).hexdigest(),
            'pixel_count':len(colors)}


def software_fixture(ref: dict) -> bytes:
    """Synthetic fixture for self-tests ONLY, never claimed as captured hardware."""
    body = bytearray()
    for row in ref['results']:
        body.extend(serialize_result(row['tag'], row['error'], 123))
    body.extend(encode_frame(sequence=0,error=False,frame_crc=ref['frame_crc32'],
                             good=1,bad=0,aborted=0,dropped=0))
    return bytes(body)


def attest(script: dict, capture: bytes, *, chunk_size=7) -> dict:
    ref = reference(script)
    if type(capture) is not bytes or len(capture) > MAX_CAPTURE_BYTES:
        raise ValueError('capture must be bytes no larger than 16 MiB')
    if type(chunk_size) is not int or chunk_size < 1:
        raise ValueError('chunk_size must be positive integer')
    decoder = HostStreamDecoder()
    seq = FrameSequenceAudit()
    replies = []
    frames = []
    failures = []
    for offset in range(0,len(capture),chunk_size):
        for record in decoder.feed(capture[offset:offset+chunk_size]):
            if record['kind'] == 'result':
                if frames:
                    failures.append('result_received_after_frame_telemetry')
                replies.append(record)
            else:
                seq.consume(record)
                frames.append(record)
                if len(replies) != len(ref['results']):
                    failures.append('frame_before_all_command_completions')
    end = decoder.finish()
    if end['invalid_candidates'] or end['discarded_bytes'] or end['incomplete_tail_bytes']:
        failures.append('invalid_or_truncated_host_stream')
    if len(replies) != len(ref['results']):
        failures.append('missing_or_duplicate_command_completions')
    for i,(actual,expected) in enumerate(zip(replies,ref['results'])):
        if actual['tag'] != expected['tag']:
            failures.append(f'completion_tag_or_order_mismatch_{i}')
        if actual['error'] != expected['error']:
            failures.append(f'completion_status_mismatch_{i}')
    if not frames:
        failures.append('no_complete_frame_telemetry')
    # A single final PRESENT permits exactly one frame telemetry record, not
    # an arbitrary number of repeated valid-CRC records with the same pixels.
    # With the required reset-before-capture policy the cumulative good-frame
    # count must also be exactly one.  Counters >1 indicate preexisting traffic,
    # unintended scanouts, or a capture that cannot satisfy this contract.
    if len(frames) != 1:
        failures.append('unexpected_frame_telemetry_count')
    for i,frame in enumerate(frames):
        if frame['error'] or frame['bad'] or frame['aborted'] or frame['good'] == 0:
            failures.append(f'frame_error_or_abort_{i}')
        if frame['good'] != 1:
            failures.append(f'frame_single_shot_counter_mismatch_{i}')
        if frame['frame_crc'] != ref['frame_crc32']:
            failures.append(f'frame_pixel_crc_mismatch_{i}')
    report = seq.report()
    if report['minimum_sequence_gaps_mod_65536'] or report['same_sequence_ambiguous'] or report['drop_count_regressions'] or report['observed_drop_counter_increments'] or any(f['dropped'] for f in frames):
        failures.append('frame_sequence_or_drop_ambiguity')
    if frames and frames[0]['sequence'] != 0:
        # Capture's first frame is specified as sequence zero after reset.
        failures.append('expected_first_frame_sequence_zero')
    return {'kind':'A0_P52_SINGLE_SHOT_CAPTURE_COMPARISON',
            'evidence_level':'SOFTWARE_REFERENCE_VS_SUPPLIED_BYTES_NOT_RTL_OR_HARDWARE',
            'status':'PASS' if not failures else 'FAIL',
            'failure_reasons':sorted(set(failures)),
            'reference':ref,
            'observed':{'completion_count':len(replies),'frame_count':len(frames),
                        'decoder':end,'sequence':report,
                        'capture_sha256':hashlib.sha256(capture).hexdigest()}}


def main(argv=None):
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--script',type=Path,required=True)
    ap.add_argument('--capture',type=Path,help='binary host capture from external test fixture')
    ap.add_argument('--make-software-fixture',type=Path,
                    help='create explicitly SYNTHETIC capture for self-testing, not device evidence')
    ap.add_argument('--report',type=Path)
    args=ap.parse_args(argv)
    if (args.capture is None) == (args.make_software_fixture is None):
        ap.error('supply exactly one of --capture or --make-software-fixture')
    try:
        script = load_script(args.script)
        ref = reference(script)
        if args.make_software_fixture:
            args.make_software_fixture.parent.mkdir(parents=True,exist_ok=True)
            args.make_software_fixture.write_bytes(software_fixture(ref))
            report={'kind':'A0_P52_SYNTHETIC_FIXTURE',
                    'evidence_level':'SOFTWARE_ONLY_NOT_DEVICE_EVIDENCE',
                    'reference':ref,'output':str(args.make_software_fixture)}
        else:
            if args.capture.stat().st_size > MAX_CAPTURE_BYTES:
                raise ValueError('capture larger than 16 MiB')
            report=attest(script,args.capture.read_bytes())
        doc=json.dumps(report,indent=2,sort_keys=True)+'\n'
        if args.report:
            args.report.parent.mkdir(parents=True,exist_ok=True)
            args.report.write_text(doc,encoding='utf-8')
        else:
            print(doc,end='')
        return 0 if report.get('status')!='FAIL' else 1
    except (OSError,ValueError,RuntimeError) as exc:
        print(f'P52 ERROR: {exc}',file=sys.stderr)
        return 2

if __name__=='__main__':
    sys.exit(main())
