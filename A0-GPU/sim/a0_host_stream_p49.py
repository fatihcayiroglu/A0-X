"""P49 incremental host capture parser: software-only tool, NOT GPU execution.

Resynchronizes after corrupted P46 A0GR/16 and P48 A0GF/32 packets.  CRC
and canonical version/flags must validate before emitting any record.
Stream-level corruption cannot be repaired, only reported.  On transport reset
call reset() and retain the resulting discontinuity in your capture report.
"""
try:
    from a0_frame_telemetry_p48 import decode_host_frames
except ModuleNotFoundError:
    from .a0_frame_telemetry_p48 import decode_host_frames

SIZE = {b'A0GR': 16, b'A0GF': 32}


class HostStreamDecoder:
    def __init__(self):
        self.reset()

    def reset(self):
        self.buffer = bytearray()
        self.invalid_candidates = 0
        self.discarded_bytes = 0
        self.decoded_packets = 0

    def feed(self, data):
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError('input must be binary bytes')
        found = []
        # Bound internal memory use independently of caller chunk size.
        for start in range(0, len(data), 4096):
            self.buffer.extend(data[start:start + 4096])
            while len(self.buffer) >= 4:
                magic = bytes(self.buffer[:4])
                size = SIZE.get(magic)
                if size is None:
                    del self.buffer[0]
                    self.discarded_bytes += 1
                    continue
                if len(self.buffer) < size:
                    break
                candidate = bytes(self.buffer[:size])
                try:
                    record, = decode_host_frames(candidate)
                except ValueError:
                    self.invalid_candidates += 1
                    del self.buffer[0]
                    self.discarded_bytes += 1
                    continue
                found.append(record)
                self.decoded_packets += 1
                del self.buffer[:size]
        # When there are <4 bytes left, discard noise but retain prefixes.
        # Eg `A0G` can become `A0GF` or `A0GR` in the next chunk.
        possible_prefixes = (b'A', b'A0', b'A0G')
        if len(self.buffer) < 4:
            while self.buffer and bytes(self.buffer) not in possible_prefixes:
                del self.buffer[0]
                self.discarded_bytes += 1
        return found

    def finish(self):
        """Return whether a recognizable packet was truncated at end of capture."""
        truncated = len(self.buffer) >= 4 and bytes(self.buffer[:4]) in SIZE
        return {'invalid_candidates': self.invalid_candidates,
                'discarded_bytes': self.discarded_bytes,
                'decoded_packets': self.decoded_packets,
                'incomplete_tail_bytes': len(self.buffer),
                'truncated_packet': truncated}


class FrameSequenceAudit:
    """Modulo-2^16 gaps are minimum *observable* gaps, not exact losses.

    The 16-bit sequence can alias after 65536 events, so this auditor never
    reports its gap count as an absolute drop count. No inferred device reset.
    """
    def __init__(self):
        self.previous = None
        self.previous_dropped = None
        self.telemetry_packets = 0
        self.minimum_sequence_gaps = 0
        self.same_sequence = 0
        self.drop_count_regressions = 0
        self.observed_drop_increments = 0

    def consume(self, record):
        if record['kind'] != 'frame':
            return
        seq = record['sequence']
        dropped = record['dropped']
        if self.previous is not None:
            delta = (seq - self.previous) & 0xffff
            if delta == 0:
                # Could also be exactly 65536 events: ambiguous.
                self.same_sequence += 1
            else:
                self.minimum_sequence_gaps += delta - 1
        if self.previous_dropped is not None:
            if dropped < self.previous_dropped:
                self.drop_count_regressions += 1  # possible device reset
            else:
                self.observed_drop_increments += dropped - self.previous_dropped
        self.previous = seq
        self.previous_dropped = dropped
        self.telemetry_packets += 1

    def report(self):
        return {'telemetry_packets': self.telemetry_packets,
                'minimum_sequence_gaps_mod_65536': self.minimum_sequence_gaps,
                'same_sequence_ambiguous': self.same_sequence,
                'drop_count_regressions': self.drop_count_regressions,
                'observed_drop_counter_increments': self.observed_drop_increments,
                'sequence_wrap_ambiguity': True}
