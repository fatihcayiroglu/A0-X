"""P119 strict stream/epoch reconciler for A0GR/A0GF/A0GL.

Software-only: byte CRCs are not signatures, and caller-supplied final counters
are not independent hardware evidence. The first parse error poisons the session.
"""
from __future__ import annotations

import hashlib
from a0_p118_loss_notice import decode_p118_stream

MAGICS = {b'A0GR': 16, b'A0GF': 32, b'A0GL': 32}
MAX_U32 = 0xffffffff


def _integer(value, name, *, minimum=0, maximum=MAX_U32):
    if type(value) is not int or value < minimum or value > maximum:
        raise ValueError(f'{name} outside integer range')
    return value


class EpochReconciler:
    """Incremental bounded-record parser, with strict per-reset-epoch accounting.

    Any reset splits epochs and REQUIRES separately verified reset evidence;
    this class does not infer resets or authenticate a device. A caller-supplied
    name merely labels the capture. No PASS before a complete final snapshot.
    """

    def __init__(self, epoch: str):
        if type(epoch) is not str or not epoch.strip() or len(epoch) > 128:
            raise ValueError('epoch requires a nonempty externally assigned label')
        self.epoch = epoch
        self._buffer = bytearray()
        self._digest = hashlib.sha256()
        self._closed = False
        self._poisoned = False
        self.frame_count = 0
        self.result_tags: list[int] = []
        self.error_results = 0
        self.loss_notices = 0
        self.last_notice_dropped = 0
        self.last_counters = {'good': 0, 'bad': 0, 'aborted': 0, 'dropped': 0}
        self.total_bytes = 0
        self.total_packets = 0

    def feed(self, data: bytes) -> None:
        if self._closed or self._poisoned:
            raise ValueError('session is closed or invalidated')
        if type(data) is not bytes:
            self._poisoned = True
            raise ValueError('feed requires bytes')
        try:
            self._digest.update(data)
            self.total_bytes += len(data)
            # Process input in capped slices, then discard parsed prefix once.
            # Avoid O(n^2) front-deletions on 65k+ packet captures.
            for off in range(0, len(data), 65536):
                self._buffer.extend(data[off:off + 65536])
                cursor = 0
                while len(self._buffer) - cursor >= 4:
                    size = MAGICS.get(bytes(self._buffer[cursor:cursor + 4]))
                    if not size:
                        raise ValueError('unknown packet magic')
                    if len(self._buffer) - cursor < size:
                        break
                    wire = bytes(self._buffer[cursor:cursor + size])
                    cursor += size
                    row, = decode_p118_stream(wire)
                    self._accept(row)
                    self.total_packets += 1
                if cursor:
                    self._buffer = self._buffer[cursor:]
                if len(self._buffer) > 31:
                    raise ValueError('packet buffer limit violated')
        except (ValueError, TypeError):
            self._poisoned = True
            raise

    def _accept(self, row: dict) -> None:
        kind = row['kind']
        if kind == 'result':
            # A0GR packet CRC/status have already been decoded strictly.
            self.result_tags.append(row['tag'])
            self.error_results += int(row['error'])
            return
        for key in ('good', 'bad', 'aborted', 'dropped'):
            if row[key] < self.last_counters[key]:
                raise ValueError(f'{key} counter regressed within reset epoch')
        # A0GF sequence = number of *attempts* before this accepted frame.
        # A0GL sequence = number of attempts when the loss notice was queued.
        # Previous accepted frames plus cumulative dropped events must account
        # for every attempt. Comparison is modulo 2^16 by wire contract.
        expected_seq = (self.frame_count + row['dropped']) & 0xffff
        if row['sequence'] != expected_seq:
            raise ValueError(f'{kind} sequence discontinuity: got {row["sequence"]}, expected {expected_seq}')
        if kind == 'frame':
            self.frame_count += 1
        elif kind == 'loss_notice':
            if row['dropped'] <= self.last_notice_dropped:
                raise ValueError('duplicate or stale loss notice')
            self.loss_notices += 1
            self.last_notice_dropped = row['dropped']
        else:
            raise ValueError('unexpected record kind')
        self.last_counters = {k: row[k] for k in self.last_counters}

    def finalize(self, *, final_attempted: int, final_dropped: int,
                 expected_result_tags: list[int] | None = None) -> dict:
        if self._closed or self._poisoned:
            raise ValueError('session is closed or invalidated')
        # The result may only be claimed for a complete, externally bounded epoch.
        self._closed = True
        _integer(final_attempted, 'final_attempted', maximum=2**53-1)
        _integer(final_dropped, 'final_dropped', maximum=MAX_U32-1)
        if self._buffer:
            raise ValueError('truncated terminal packet')
        if final_dropped > final_attempted:
            raise ValueError('drop count exceeds total attempts')
        if self.frame_count + final_dropped != final_attempted:
            raise ValueError('missing or duplicated frame/attempt reconciliation')
        if self.last_counters['dropped'] != final_dropped:
            raise ValueError('final drops not witnessed in stream')
        if final_dropped and self.last_notice_dropped != final_dropped:
            raise ValueError('missing terminal A0GL loss notice')
        if expected_result_tags is not None:
            if type(expected_result_tags) is not list or any(type(t) is not int or not 0 <= t <= 65535 for t in expected_result_tags):
                raise ValueError('invalid expected result tags')
            if self.result_tags != expected_result_tags or self.error_results:
                raise ValueError('host command result mismatch or error result')
        return {
            'schema': 'A0-P119-EPOCH-RECONCILE-v1',
            'status': 'SOFTWARE_STREAM_CONSISTENT',
            'epoch_label': self.epoch,
            'sha256': self._digest.hexdigest(),
            'packet_count': self.total_packets,
            'byte_count': self.total_bytes,
            'accepted_frame_packets': self.frame_count,
            'final_attempted': final_attempted,
            'final_dropped': final_dropped,
            'loss_notices': self.loss_notices,
            'result_packets': len(self.result_tags),
            'result_error_packets': self.error_results,
            'physical_hardware_verified': False,
            'reset_proven': False,
            'final_counters_externally_authenticated': False,
        }


def audit_epoch(capture: bytes, *, epoch: str, final_attempted: int,
                final_dropped: int, expected_result_tags: list[int] | None = None) -> dict:
    v = EpochReconciler(epoch)
    v.feed(capture)
    return v.finalize(final_attempted=final_attempted, final_dropped=final_dropped,
                      expected_result_tags=expected_result_tags)
