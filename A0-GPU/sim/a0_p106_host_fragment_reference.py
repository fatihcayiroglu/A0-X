"""Logical P106 host-to-double-bank oracle; NOT real RTL or timing."""
from a0_p105_host_dual_bank_reference import P105HostSession
from a0_host_extended_p106 import decode_host_command
from a0_graphics_command_p43 import CLEAR,TRIANGLE,PRESENT
from a0_host_protocol_p44 import encode_result, Result, COMMAND_ERROR, SUCCESS

class P106HostSession(P105HostSession):
    def issue(self, frame:bytes, *, ready=lambda t: True, limit=100000):
        draw=decode_host_command(frame)
        command=draw.command
        self.tags.append(command.tag)
        error=False
        if command.opcode==CLEAR:
            try:self.gpu.clear(command.color,0xffffff)
            except RuntimeError:error=True
        elif command.opcode==TRIANGLE:
            try:
                v=command.vertices
                self.gpu.triangle(((v[0],v[1]),(v[2],v[3]),(v[4],v[5])),
                                  command.color,draw.depth,draw.state)
            except RuntimeError:error=True
        elif command.opcode==PRESENT:
            if not self.gpu.present():error=True
            else:
                for i in range(limit):
                    _,_,_,flipped=self.clock(pixel_ready=bool(ready(i)))
                    if flipped:break
                else:raise TimeoutError('PRESENT swap blocked')
        else:error=True
        result=encode_result(Result(COMMAND_ERROR if error else SUCCESS,command.tag,0))
        self.results.append(result)
        return result
