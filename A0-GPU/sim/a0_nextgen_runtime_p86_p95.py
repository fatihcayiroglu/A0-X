"""P86-P95 deterministic SOFTWARE command queue; not a kernel driver or PCIe.

No command performs arbitrary user code execution. All operations are bounded,
resource-typed, generation-checked and entirely in memory.
"""
from dataclasses import dataclass
from copy import deepcopy
import struct
import zlib
from a0_nextgen_graphics_p56_p80 import Framebuffer, GraphicsState
from a0_nextgen_compute_p81_p85 import dispatch, Kernel


class DeviceFault(ValueError):
    pass


@dataclass(frozen=True)
class Buffer:
    data: bytes


class ResourceTable:
    def __init__(self, capacity=256):
        if not 1<=capacity<=4096: raise ValueError('capacity')
        self.capacity=capacity
        self.slots={}
        self.generations={}

    def allocate(self, resource):
        if not isinstance(resource,(Buffer,Framebuffer)):
            raise DeviceFault('unsupported resource type')
        for slot in range(1,self.capacity+1):
            if slot not in self.slots:
                gen=self.generations.get(slot,1)
                # Never recycle a 16-bit generation; old handles could alias.
                # Exhausted slots are permanently retired in this prototype.
                if gen>0xffff: continue
                self.slots[slot]=resource
                return (gen<<16)|slot
        raise DeviceFault('resource table full')

    def get(self, handle, klass=None):
        if type(handle) is not int:raise DeviceFault('bad handle')
        slot=handle&0xffff; gen=handle>>16
        if not 1<=slot<=self.capacity or not 1<=gen<=0xffff or gen!=self.generations.get(slot,1) or slot not in self.slots:
            raise DeviceFault('stale or unknown resource')
        obj=self.slots[slot]
        if klass is not None and not isinstance(obj,klass):
            raise DeviceFault('resource type mismatch')
        return obj

    def release(self,handle):
        self.get(handle)
        slot=handle&0xffff
        del self.slots[slot]
        # 65536 marks an exhausted slot and is never returned as a handle.
        self.generations[slot]=self.generations.get(slot,1)+1

    def replace(self,handle,resource):
        previous=self.get(handle)
        if type(resource) is not type(previous):
            raise DeviceFault('resource replacement type mismatch')
        self.slots[handle&0xffff]=resource


@dataclass(frozen=True)
class Command:
    op: str
    handle: int = 0
    payload: object = None


class CommandBuffer:
    """Sealed command snapshot for the single-process software reference.

    Public accessors return copies of the command payloads; callers cannot
    silently modify the admitted command sequence or its nested arguments.
    This is not a security sandbox for arbitrary malicious Python objects.
    """
    def __init__(self):
        self._commands=[]
        self._sealed=False

    @property
    def commands(self):
        return tuple(deepcopy(self._commands))

    @property
    def sealed(self):
        return self._sealed

    def append(self,command):
        if self.sealed: raise DeviceFault('sealed command buffer')
        if not isinstance(command,Command): raise DeviceFault('invalid command')
        if len(self._commands)>=1024: raise DeviceFault('command count limit')
        self._commands.append(command)

    def seal(self):
        if not self._commands: raise DeviceFault('empty command buffer')
        if not self._sealed:
            # Copy before sealing: mutations to caller-owned lists/GraphicsState
            # must not change the commands that execute later.
            self._commands=tuple(deepcopy(self._commands))
            self._sealed=True
        return self.commands


class SoftwareQueue:
    def __init__(self, resources):
        self.resources=resources
        self.next_fence=1
        self.completed=0
        self.logs=[]
        self.outputs={}
        self.pending_access={}

    def submit(self, cmd_buffer):
        if not cmd_buffer.sealed:raise DeviceFault('unsealed command buffer')
        fence=self.next_fence
        self.next_fence+=1
        for index,c in enumerate(cmd_buffer.commands):
            try:
                self._execute(c,fence,index)
            except (ValueError,TypeError,IndexError) as exc:
                self.logs.append((fence,index,'FAULT',str(exc)))
                self.completed=fence
                raise DeviceFault(f'command {index} failed: {exc}') from exc
            self.logs.append((fence,index,c.op,'OK'))
        self.completed=fence
        return fence

    def wait(self,fence):
        if type(fence) is not int or not 0<fence<self.next_fence:raise DeviceFault('unknown fence')
        return fence<=self.completed

    def _access(self,handle,mode):
        prior=self.pending_access.get(handle)
        if prior and (mode=='write' or prior=='write'):
            raise DeviceFault('resource hazard; BARRIER required')
        self.pending_access[handle]=mode

    def _execute(self,c,fence,index):
        if c.op=='BARRIER':
            self.pending_access.clear();return
        if c.op=='UPLOAD':
            self.resources.get(c.handle,Buffer)
            self._access(c.handle,'write')
            if not isinstance(c.payload,bytes) or len(c.payload)>1048576:raise DeviceFault('upload payload')
            self.resources.replace(c.handle,Buffer(c.payload));return
        if c.op=='READBACK':
            resource=self.resources.get(c.handle,Buffer)
            self._access(c.handle,'read')
            self.outputs[(fence,index)]=resource.data;return
        if c.op=='CLEAR':
            fb=self.resources.get(c.handle,Framebuffer)
            self._access(c.handle,'write')
            fb.clear(c.payload);return
        if c.op=='DRAW':
            fb=self.resources.get(c.handle,Framebuffer)
            self._access(c.handle,'write')
            vertices,state=c.payload
            fb.draw(vertices,state);return
        if c.op=='PRESENT':
            fb=self.resources.get(c.handle,Framebuffer)
            self._access(c.handle,'read')
            self.outputs[(fence,index)]=(fb.crc32(),fb.rgb_bytes());return
        if c.op=='DISPATCH':
            buf=self.resources.get(c.handle,Buffer)
            self._access(c.handle,'write')
            kernel,workgroups,mask=c.payload
            if len(buf.data)%4:raise DeviceFault('unaligned int32 buffer')
            values=struct.unpack('<'+'i'*(len(buf.data)//4),buf.data)
            result=dispatch(kernel,values,workgroups=workgroups,active_mask=mask)
            self.resources.replace(c.handle,Buffer(struct.pack('<'+'i'*len(result.data),*result.data)))
            return
        raise DeviceFault('unknown operation')


# Bounded, versioned host envelope for trace exports; unrelated to P44 wire.
_HEAD=struct.Struct('<4sBBHI')
MAX_HOST_PAYLOAD=65536

def pack_trace(payload:bytes,kind=1,sequence=0):
    if not isinstance(payload,bytes) or len(payload)>MAX_HOST_PAYLOAD or type(kind) is not int or not 0<=kind<256 or type(sequence) is not int or not 0<=sequence<65536:
        raise DeviceFault('invalid trace envelope')
    data=_HEAD.pack(b'A0T1',1,kind,sequence,len(payload))+payload
    return data+struct.pack('<I',zlib.crc32(data)&0xffffffff)


def unpack_trace(frame:bytes):
    if not isinstance(frame,bytes) or len(frame)<_HEAD.size+4 or len(frame)>_HEAD.size+MAX_HOST_PAYLOAD+4:
        raise DeviceFault('trace frame length')
    magic,version,kind,sequence,size=_HEAD.unpack(frame[:_HEAD.size])
    if magic!=b'A0T1' or version!=1 or size!=len(frame)-_HEAD.size-4:
        raise DeviceFault('invalid trace header')
    if struct.unpack('<I',frame[-4:])[0] != zlib.crc32(frame[:-4])&0xffffffff:
        raise DeviceFault('trace CRC')
    return kind,sequence,frame[_HEAD.size:-4]
