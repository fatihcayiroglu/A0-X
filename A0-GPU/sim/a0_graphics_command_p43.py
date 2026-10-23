"""P43 cycle-level REFERENCE intent (not SystemVerilog execution).

A single in-flight command adapter. Inputs to tick are the lower layer's
pre-clock ready and completion pulses. Status/payloads are sampled pre-edge.
"""
from dataclasses import dataclass

CLEAR, TRIANGLE, PRESENT, INVALID = range(4)


@dataclass(frozen=True)
class Command:
    opcode: int
    tag: int
    color: int = 0
    vertices: tuple = (0, 0, 0, 0, 0, 0)


@dataclass(frozen=True)
class Pins:
    cmd_ready: bool
    completion_valid: bool
    completion_tag: int
    completion_error: bool
    busy: bool
    clear_valid: bool
    tri_valid: bool
    swap_valid: bool
    command: Command | None


class GraphicsFrontend:
    def __init__(self, tag_bits=16):
        if tag_bits < 1:
            raise ValueError('tag_bits must be positive')
        self.mask = (1 << tag_bits)-1
        self.reset()

    def reset(self):
        self.state = 'IDLE'
        self.active = Command(CLEAR, 0)
        self.error = False

    def outputs(self):
        op = self.active.opcode
        return Pins(self.state == 'IDLE', self.state == 'RESPONSE',
                    self.active.tag, self.error, self.state != 'IDLE',
                    self.state == 'OFFER' and op == CLEAR,
                    self.state == 'OFFER' and op == TRIANGLE,
                    self.state == 'OFFER' and op == PRESENT,
                    self.active)

    def tick(self, command=None, *, completion_ready=True,
             clear_ready=False, tri_ready=False, swap_ready=False,
             clear_done=False, tri_done=False, swap_done=False,
             render_initialized=True, rst_n=True):
        out = self.outputs()
        if not rst_n:
            self.reset()
            return out
        if self.state == 'IDLE' and command is not None:
            if not (0 <= command.opcode <= 3):
                raise ValueError('invalid encoded command')
            if len(command.vertices) != 6:
                raise ValueError('six signed 16-bit vertex coordinates expected')
            if not all(-32768 <= x <= 32767 for x in command.vertices):
                raise ValueError('vertex coordinate exceeds signed 16-bit range')
            self.active = Command(command.opcode, command.tag & self.mask,
                                  command.color & 0xFFFFFF, tuple(command.vertices))
            self.error = (command.opcode == INVALID or
                          (command.opcode != CLEAR and not render_initialized))
            self.state = 'RESPONSE' if self.error else 'OFFER'
        elif self.state == 'OFFER':
            if ((out.clear_valid and clear_ready) or (out.tri_valid and tri_ready) or
                    (out.swap_valid and swap_ready)):
                self.state = 'WAIT_DONE'
        elif self.state == 'WAIT_DONE':
            if ((self.active.opcode == CLEAR and clear_done) or
                    (self.active.opcode == TRIANGLE and tri_done) or
                    (self.active.opcode == PRESENT and swap_done)):
                self.error = False
                self.state = 'RESPONSE'
        elif self.state == 'RESPONSE' and completion_ready:
            self.state = 'IDLE'
        return out
