"""P105 host + double-bank + accepted-pixel CRC *software oracle*.

Logical transactions, NOT RTL timing, PCIe, or a proof that P104 RTL works.
Legacy 32-byte P44 commands have no fragment state: depth ALWAYS, no depth
writes, no blending, no scissor. Diagnostic packet availability/backpressure
is outside this class; P46/P48/P49 clock models own that separate concern.
"""
from a0_graphics_command_p43 import CLEAR, TRIANGLE, PRESENT
from a0_host_protocol_p44 import decode_command, encode_result, Result, SUCCESS, COMMAND_ERROR
from a0_p104_double_bank_reference import P104DoubleBankReference
from a0_p102_fragment_reference import FragmentState
from a0_frame_integrity_p47 import FrameIntegritySpec, Beat
from a0_frame_telemetry_p48 import encode_frame, decode_host_frames

LEGACY_FRAGMENT = FragmentState(depth_op=0, depth_write=False, blend=False, alpha=255, scissor=None)

class P105HostSession:
    def __init__(self, width, height):
        self.gpu = P104DoubleBankReference(width, height)
        self.guard = FrameIntegritySpec(width, height)
        self.reset()

    def reset(self):
        self.gpu.reset()
        self.guard.reset()
        self.results = []
        self.telemetry = []
        self.pixels = []
        self.sequence = 0
        self.tags = []

    def clock(self, *, pixel_ready=True):
        active = self.gpu.active
        px,accepted,done,flipped = self.gpu.step(pixel_ready=pixel_ready)
        beat = None if px is None else Beat(px.x,px.y,px.color,px.first,px.line_end,px.frame_end)
        observation = self.guard.tick(stream_active=active, pixel_valid=px is not None,
                                      pixel_ready=pixel_ready, beat=beat)
        if accepted:
            self.pixels.append(px)
        if observation.frame_valid:
            self.telemetry.append(encode_frame(sequence=self.sequence,
                error=observation.frame_error, frame_crc=observation.frame_crc32,
                good=self.guard.good_frames, bad=self.guard.bad_frames,
                aborted=self.guard.aborted_frames, dropped=0))
            self.sequence = (self.sequence+1) & 65535
        return px,accepted,done,flipped

    def issue(self, frame: bytes, *, ready=lambda t: True, limit=100000):
        """Decode a canonical P44 packet, run logical command, return A0GR bytes.

        PRESENT result is recorded when bank swap commits. Earlier front frame
        may finish in that interval, allowing telemetry before this result.
        Invalid CRC/wire packets are rejected, not dispatched or ACKed.
        """
        command = decode_command(frame)
        self.tags.append(command.tag)
        error = False
        if command.opcode == CLEAR:
            try:self.gpu.clear(command.color, 0xffffff)
            except RuntimeError:error=True
        elif command.opcode == TRIANGLE:
            try:
                v=command.vertices
                self.gpu.triangle(((v[0],v[1]),(v[2],v[3]),(v[4],v[5])),
                                  command.color, 0xffffff, LEGACY_FRAGMENT)
            except RuntimeError:error=True
        elif command.opcode == PRESENT:
            if not self.gpu.present():
                error=True
            else:
                for i in range(limit):
                    _,_,_,flipped=self.clock(pixel_ready=bool(ready(i)))
                    if flipped:break
                else:raise TimeoutError('PRESENT bank swap blocked')
        else:
            error=True
        packet = encode_result(Result(COMMAND_ERROR if error else SUCCESS, command.tag, 0))
        self.results.append(packet)
        return packet

    def drain(self, *, ready=lambda t: True, limit=100000):
        """Drain one current scan and return only pixels accepted during drain."""
        if not self.gpu.active:
            return []
        start=len(self.pixels)
        for i in range(limit):
            _,_,done,_=self.clock(pixel_ready=bool(ready(i)))
            if done:return self.pixels[start:]
        raise TimeoutError('scanout stalled')

    def capture(self, *, order=None):
        """Build a packet-atomic logical capture; no assertion of cycle timing.

        order is a sequence of 'result'/'frame' labels. The output is valid
        host framing but is not a reproduction of hardware arbitration timing.
        """
        if order is None:
            order=['result']*len(self.results)+['frame']*len(self.telemetry)
        if order.count('result')!=len(self.results) or order.count('frame')!=len(self.telemetry):
            raise ValueError('capture must contain each packet exactly once')
        if any(x not in ('result','frame') for x in order):
            raise ValueError('unknown capture lane')
        indices={'result':0,'frame':0}
        sources={'result':self.results,'frame':self.telemetry}
        chunks=[]
        for label in order:
            chunks.append(sources[label][indices[label]])
            indices[label]+=1
        output=b''.join(chunks)
        assert len(decode_host_frames(output))==len(order)
        return output
