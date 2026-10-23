#!/usr/bin/env python3
"""Audit a binary capture of A0-X logical host reply frames.

This consumes a capture obtained elsewhere; it does not communicate with
hardware and cannot authenticate a physical device or establish RTL validity.
"""
import argparse
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'sim'))
from a0_host_stream_p49 import HostStreamDecoder, FrameSequenceAudit


def audit_capture(path, *, chunk_size=4096):
    if chunk_size < 1: raise ValueError('chunk_size must be positive')
    d=HostStreamDecoder()
    audit=FrameSequenceAudit()
    results=[]
    frames=0
    with open(path,'rb') as f:
        for chunk in iter(lambda:f.read(chunk_size), b''):
            for record in d.feed(chunk):
                if record['kind']=='result':
                    results.append({'tag':record['tag'],'error':record['error'],
                                    'cycles':record['cycles']})
                else:
                    frames+=1
                    audit.consume(record)
    return {'kind':'A0_P49_CAPTURE_AUDIT_SOFTWARE_ONLY',
            'source':str(path),
            'command_results':results,
            'frame_packets':frames,
            'decoder':d.finish(),
            'sequence_audit':audit.report()}


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture',required=True,type=Path)
    parser.add_argument('--report',type=Path)
    parser.add_argument('--chunk-size',type=int,default=4096)
    parser.add_argument('--allow-corruption',action='store_true',
                        help='Report detected invalid/truncated packets but return 0')
    parser.add_argument('--require-lossless',action='store_true',
                        help='Fail if unambiguous frame-sequence gaps or telemetry drop increments appear')
    a=parser.parse_args(argv)
    try:
        data=audit_capture(a.capture,chunk_size=a.chunk_size)
    except (ValueError,OSError) as e:
        parser.error(str(e))
    output=json.dumps(data,indent=2,sort_keys=True)+'\n'
    if a.report:
        a.report.write_text(output,encoding='utf-8')
    else:print(output,end='')
    dec=data['decoder']
    is_corrupt=bool(dec['invalid_candidates'] or dec['discarded_bytes'] or
                    dec['incomplete_tail_bytes'])
    aud=data['sequence_audit']
    gap=bool(aud['minimum_sequence_gaps_mod_65536'] or
             aud['same_sequence_ambiguous'] or
             aud['drop_count_regressions'] or
             aud['observed_drop_counter_increments'])
    if is_corrupt and not a.allow_corruption:return 1
    if gap and a.require_lossless:return 1
    return 0

if __name__=='__main__':sys.exit(main())
