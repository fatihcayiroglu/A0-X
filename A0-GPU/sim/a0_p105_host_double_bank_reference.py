"""P105 host<->double-bank SOFTWARE transaction reference; never RTL evidence.

Only the frozen P44 v1 CLEAR/TRIANGLE/PRESENT/INVALID subset is supported.
P44 has no programmable depth, blend, scissor, shader or texture fields.
Result cycles here are 0 placeholders, not a model of device elapsed clocks.
An ideal lossless host is assumed (telemetry queue drop behavior not modeled).
"""
from __future__ import annotations

import zlib

from a0_graphics_command_p43 import CLEAR, TRIANGLE, PRESENT, INVALID, Command
from a0_host_protocol_p44 import decode_command, encode_command, encode_result, Result
from a0_frame_telemetry_p48 import encode_frame
from a0_host_stream_p49 import HostStreamDecoder
from a0_p104_double_bank_reference import P104DoubleBankReference
from a0_p102_fragment_reference import FragmentState


class P105HostReference:
    def __init__(self, width: int, height: int):
        self.device = P104DoubleBankReference(width, height)
        self.reset()

    def reset(self):
        self.device.reset()
        self.result_events = []
        self.frame_events = []
        self.events = []
        self.pending_tag = None
        self.colors = []
        self.frame_count = 0

    def _result(self, tag: int, error: bool):
        packet = encode_result(Result(status=int(error), tag=tag, cycles=0))
        self.events.append(packet)
        self.result_events.append((tag, error))

    def send(self, wire: bytes, *, scan_enable=True):
        """Accept exactly one valid P44 packet. Returns True if dispatched.

        CRC/magic/version/canonical rejection raises ValueError with no change.
        A pending PRESENT blocks new commands until the bank swap commits.
        """
        command = decode_command(wire)
        if self.pending_tag is not None:
            raise RuntimeError('frontend backpressure: awaiting PRESENT retirement')
        if command.opcode == INVALID:
            self._result(command.tag, True)
        elif command.opcode == CLEAR:
            self.device.clear(command.color, 0xffffff)
            self._result(command.tag, False)
        elif command.opcode == TRIANGLE:
            if not self.device.render_initialized:
                self._result(command.tag, True)
            else:
                v = command.vertices
                vertices = ((v[0],v[1]),(v[2],v[3]),(v[4],v[5]))
                self.device.triangle(vertices, command.color, 0,
                    FragmentState(depth_op=0,depth_write=False,blend=False))
                self._result(command.tag, False)
        elif command.opcode == PRESENT:
            if not self.device.render_initialized:
                self._result(command.tag, True)
            elif not scan_enable:
                raise RuntimeError('PRESENT waits for scan_enable permission')
            else:
                if not self.device.present(scan_enable=True):
                    raise RuntimeError('PRESENT backpressure')
                self.pending_tag = command.tag
        else:
            raise AssertionError('decoder accepted invalid opcode')
        return True

    def tick(self, *, pixel_ready=True):
        pixel, accepted, done, swap = self.device.step(pixel_ready=pixel_ready)
        if swap:
            if self.pending_tag is None:
                raise AssertionError('swap without associated PRESENT')
            self._result(self.pending_tag, False)
            self.pending_tag = None
        if pixel is not None and accepted:
            self.colors.append(pixel.color)
        if done:
            if len(self.colors) != self.device.width*self.device.height:
                raise AssertionError('short software frame')
            rgb_bytes = b''.join(c.to_bytes(3,'little') for c in self.colors)
            crc = zlib.crc32(rgb_bytes)
            self.frame_events.append((self.frame_count & 0xffff, crc))
            self.frame_count += 1
            self.events.append(encode_frame(
                sequence=(self.frame_count-1)&0xffff, error=False,
                frame_crc=crc,good=self.frame_count,bad=0,aborted=0,dropped=0))
            self.colors.clear()
        return pixel, accepted, done, swap

    def drain(self, *, ready=lambda clock: True, limit=100000):
        initial_frames = self.frame_count
        for clock in range(limit):
            self.tick(pixel_ready=ready(clock))
            if self.frame_count > initial_frames:
                return
        raise TimeoutError('frame did not complete')

    def wire_capture(self):
        """Ideal logical ordering ONLY; not cycle-correct fair TX arbitration."""
        return b''.join(self.events)


def audit_capture(sent_commands: list[Command], expected_crcs: list[int], wire: bytes):
    """Fail-closed exact session audit. No lost/noisy packets are permissible.

    The expected CRC list MUST be supplied from a separate oracle or external
    golden image, not derived from the capture being audited. Results may be
    interleaved with frames, but each lane preserves its own relative order.
    Requires a capture that began after a known hardware reset with counters 0.
    """
    if not isinstance(wire, bytes):
        raise TypeError('capture must be bytes')
    if not expected_crcs or any(type(c) is not int or not 0 <= c <= 0xffffffff
                                for c in expected_crcs):
        raise ValueError('expected frame CRCs must be supplied')
    if any(not isinstance(c, Command) for c in sent_commands):
        raise TypeError('expected commands must be Command values')
    decoder = HostStreamDecoder()
    packets = []
    for i in range(0,len(wire),7):
        packets.extend(decoder.feed(wire[i:i+7]))
    state=decoder.finish()
    if state['invalid_candidates'] or state['discarded_bytes'] or state['incomplete_tail_bytes']:
        raise ValueError('corrupt/noisy/truncated transport capture')
    results = [p for p in packets if p['kind']=='result']
    frames = [p for p in packets if p['kind']=='frame']
    if len(results)!=len(sent_commands):
        raise ValueError('missing or extra command results')
    if len(frames)!=len(expected_crcs):
        raise ValueError('missing or extra frame telemetry')
    seen=set()
    for cmd, result in zip(sent_commands, results):
        # Tag reuse is ambiguous without an epoch identifier. Reject it.
        if cmd.tag in seen:
            raise ValueError('ambiguous repeated host tag')
        seen.add(cmd.tag)
        if result['tag'] != cmd.tag:
            raise ValueError('command tag mismatch or reordering')
        # Expected command failures: invalid opcode OR TRIANGLE/PRESENT before
        # initial CLEAR cannot be inferred solely from the opcode. Caller must
        # send valid sessions; explicit failures can be checked separately.
        if result['error']:
            raise ValueError('command error in success-only session')
    for i, (frame, crc) in enumerate(zip(frames,expected_crcs)):
        if frame['error'] or frame['frame_crc']!=crc:
            raise ValueError('wrong frame CRC or corrupt pixel sequence')
        if (frame['sequence'], frame['good'],frame['bad'],frame['aborted'],frame['dropped']) != \
           (i & 0xffff,i+1,0,0,0):
            raise ValueError('frame sequence/counter inconsistency')
    return {'commands':len(results),'frames':len(frames),'captured_bytes':len(wire),
            'clean_transport':True, 'perfect_delivery_assumed':True}
