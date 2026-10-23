#!/usr/bin/env python3
"""Offline capture auditor. External data is unauthenticated, not device proof."""
import argparse,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from a0_p118_loss_notice import audit_loss_notices

def main(argv=None):
    parser=argparse.ArgumentParser(description='Verify P118 A0GF/A0GR/A0GL captured wire')
    parser.add_argument('--capture',type=Path,required=True)
    parser.add_argument('--final-dropped',type=int,default=None)
    args=parser.parse_args(argv)
    try:
        result=audit_loss_notices(args.capture.read_bytes(),final_dropped=args.final_dropped)
    except (OSError,ValueError) as exc:
        print('P118_CAPTURE_AUDIT_FAIL:',exc,file=sys.stderr)
        return 1
    print(json.dumps(result,sort_keys=True))
    return 0
if __name__=='__main__':sys.exit(main())
