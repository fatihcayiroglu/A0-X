#!/usr/bin/env python3
"""P50 deterministic P49 arbiter pin-trace generator/checker.

Software oracle only.  The trace is not evidence that RTL works: use
run_p50_rtl_gate.py on a host with Icarus or Verilator for pin comparison.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'sim'))
from a0_fair_arbiter_p49 import FairArbiter
from a0_frame_telemetry_p48 import encode_frame
from a0_host_result_wire_p46 import serialize_result

HEADER = '# rst_n rv rb tv tb host_ready expected_host_valid expected_byte expected_result_ready expected_telemetry_ready'
COLUMNS = 10


@dataclass
class Lane:
    name: str
    count: int = 0
    index: int = 0
    cool_until: int = 0
    held: bool = False

    def reset(self, cycle: int) -> None:
        self.count = 0
        self.index = 0
        self.cool_until = cycle + 3
        self.held = False

    def frame(self) -> bytes:
        if self.name == 'result':
            return serialize_result(self.count & 0xffff, False, (self.count * 917) & 0xffffffff)
        return encode_frame(sequence=self.count & 0xffff, error=False,
                            frame_crc=(self.count * 0x1020304 + 0xdeadbeef) & 0xffffffff,
                            good=self.count, bad=0, aborted=0, dropped=0)

    def offer(self, cycle: int, enabled: bool) -> tuple[bool, int]:
        valid = self.held or self.index > 0 or (enabled and cycle >= self.cool_until)
        if valid:
            self.held = True
        return bool(valid), self.frame()[self.index] if valid else 0

    def accept(self, cycle: int, rng: random.Random) -> bool:
        self.index += 1
        length = 16 if self.name == 'result' else 32
        if self.index == length:
            self.index = 0
            self.held = False
            self.count += 1
            self.cool_until = cycle + 1 + rng.randrange(0, 4)
            return True
        return False


def build_trace(*, seed: int = 50050, cycles: int = 6000) -> tuple[str, dict]:
    if cycles < 2300 or cycles > 500_000:
        raise ValueError('cycles must be between 2300 and 500000 for minimum coverages')
    rng = random.Random(seed)
    ref = FairArbiter()
    result, telemetry = Lane('result'), Lane('telemetry')
    rows = [HEADER]
    counts = {'cycles': cycles, 'reset_cycles': 0, 'accepted_result_bytes': 0,
              'accepted_telemetry_bytes': 0, 'completed_result_frames': 0,
              'completed_telemetry_frames': 0, 'both_valid_cycles': 0,
              'host_stalls': 0, 'idle_cycles': 0, 'result_grants': 0,
              'telemetry_grants': 0, 'concurrent_contention_transfers': 0}
    # Two explicit resets; second reset occurs during a forced midframe stall.
    reset_at = {0, 1, 2, 1617, 1618}
    for cycle in range(cycles):
        reset = cycle in reset_at
        if reset:
            result.reset(cycle)
            telemetry.reset(cycle)
        # P50 exercises solo result, solo telemetry, both, and random gaps.
        rv_enable = (cycle < 550 or cycle >= 850)
        tv_enable = (cycle >= 400)
        if cycle >= 2000:
            if result.index == 0 and rng.randrange(11) == 0:
                rv_enable = False
            if telemetry.index == 0 and rng.randrange(13) == 0:
                tv_enable = False
        rv, rb = result.offer(cycle, rv_enable and not reset)
        tv, tb = telemetry.offer(cycle, tv_enable and not reset)
        ready = (rng.randrange(9) > 1) and not (1100 <= cycle < 1150)
        if 1600 <= cycle < 1619:
            ready = False
        if reset:
            ready = False
        e = ref.tick(result_valid=rv, result_byte=rb,
                     telemetry_valid=tv, telemetry_byte=tb,
                     host_ready=ready, rst_n=not reset)
        if reset:
            counts['reset_cycles'] += 1
        if rv and tv:
            counts['both_valid_cycles'] += 1
        if not rv and not tv:
            counts['idle_cycles'] += 1
        if e.valid and not ready:
            counts['host_stalls'] += 1
        if e.lane is None and ref.lane is not None:
            counts[ref.lane + '_grants'] += 1
        if e.transferred:
            if rv and tv:
                counts['concurrent_contention_transfers'] += 1
            counts['accepted_' + e.lane + '_bytes'] += 1
            ended = (result if e.lane == 'result' else telemetry).accept(cycle, rng)
            if ended:
                counts['completed_' + e.lane + '_frames'] += 1
        # e.byte can be None if no host valid; document it explicitly as zero.
        row = (int(not reset), int(rv), rb, int(tv), tb, int(ready),
               int(e.valid), e.byte if e.valid else 0,
               int(e.result_ready), int(e.telemetry_ready))
        rows.append(' '.join(map(str, row)))
    # Non-vacuity: prove both lanes moved and stalled, and resets were exercised.
    assert counts['completed_result_frames'] >= 20, counts
    assert counts['completed_telemetry_frames'] >= 20, counts
    assert counts['both_valid_cycles'] >= 100, counts
    assert counts['host_stalls'] >= 100, counts
    assert counts['reset_cycles'] == len(reset_at), counts
    assert counts['result_grants'] >= 20, counts
    assert counts['telemetry_grants'] >= 20, counts
    data = '\n'.join(rows) + '\n'
    counts.update({'kind': 'P50_PYTHON_MODEL_TRACE_NOT_RTL_EVIDENCE',
                   'seed': seed, 'sha256': hashlib.sha256(data.encode()).hexdigest(),
                   'format': 'decimal_10_fields_v1'})
    return data, counts


def verify_trace(data: str) -> dict:
    """Replay expected pins against P49 software reference; detect trace corruption."""
    lines = data.splitlines()
    if not lines or lines[0] != HEADER:
        raise ValueError('invalid P50 trace header')
    ref = FairArbiter()
    accepted = 0
    pending_result = None
    pending_telemetry = None
    for row_num, line in enumerate(lines[1:], 1):
        parts = line.split()
        if len(parts) != COLUMNS:
            raise ValueError(f'cycle {row_num}: expected 10 columns')
        try:
            (rst, rv, rb, tv, tb, ready, ev, eb, err, etr) = map(int, parts)
        except ValueError as exc:
            raise ValueError(f'cycle {row_num}: invalid integer') from exc
        if not all(x in (0, 1) for x in (rst, rv, tv, ready, ev, err, etr)):
            raise ValueError(f'cycle {row_num}: boolean out of range')
        if not all(0 <= x <= 255 for x in (rb, tb, eb)):
            raise ValueError(f'cycle {row_num}: byte out of range')
        if rst:
            if pending_result is not None and (not rv or rb != pending_result):
                raise ValueError(f'cycle {row_num}: result source violated held valid/data')
            if pending_telemetry is not None and (not tv or tb != pending_telemetry):
                raise ValueError(f'cycle {row_num}: telemetry source violated held valid/data')
        e = ref.tick(rst_n=bool(rst), result_valid=bool(rv), result_byte=rb,
                     telemetry_valid=bool(tv), telemetry_byte=tb,host_ready=bool(ready))
        got = (int(e.valid),e.byte if e.valid else 0,int(e.result_ready),int(e.telemetry_ready))
        want = (ev,eb,err,etr)
        if got != want:
            raise ValueError(f'cycle {row_num}: expected {want}, software oracle {got}')
        if not rst:
            pending_result = pending_telemetry = None
        else:
            pending_result = rb if rv and not e.result_ready else None
            pending_telemetry = tb if tv and not e.telemetry_ready else None
        if e.transferred:
            accepted += 1
    return {'cycles': len(lines)-1, 'accepted_bytes': accepted,
            'sha256': hashlib.sha256(data.encode()).hexdigest(),
            'kind': 'P50_PYTHON_ORACLE_REPLAY_ONLY'}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--summary',type=Path)
    ap.add_argument('--seed',type=int,default=50050)
    ap.add_argument('--cycles',type=int,default=6000)
    args=ap.parse_args(argv)
    data,summary=build_trace(seed=args.seed,cycles=args.cycles)
    verify_trace(data)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(data,encoding='utf-8')
    if args.summary:
        args.summary.parent.mkdir(parents=True,exist_ok=True)
        args.summary.write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
    print(json.dumps(summary,sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
