"""P118 A0GL loss notices and reference FIFO, not proof of RTL execution."""
from collections import deque
from dataclasses import dataclass
import struct
import zlib
from a0_frame_telemetry_p48 import encode_frame, decode_host_frames

LOSS_MAGIC=b'A0GL'

def _u32(v): return type(v) is int and 0 <= v <= 0xffffffff

def encode_loss_notice(*, sequence, dropped, good, bad, aborted):
    if type(sequence) is not int or not 0 <= sequence <= 65535 or not all(map(_u32,(dropped,good,bad,aborted))) or dropped==0:
        raise ValueError('invalid P118 loss notice')
    raw=struct.pack('<4sBBHIIIII',LOSS_MAGIC,1,1,sequence,dropped,good,bad,aborted,0)
    return raw+struct.pack('<I',zlib.crc32(raw))

def decode_p118_stream(data):
    if type(data) is not bytes: raise ValueError('stream must be bytes')
    frames=[];i=0
    while i<len(data):
        magic=data[i:i+4]
        n=16 if magic==b'A0GR' else 32 if magic in (b'A0GF',LOSS_MAGIC) else 0
        if not n or i+n>len(data): raise ValueError('bad or truncated P118 packet')
        blob=data[i:i+n]
        if magic!=LOSS_MAGIC:
            frames.extend(decode_host_frames(blob))
        else:
            if zlib.crc32(blob[:28])!=int.from_bytes(blob[28:],'little'):
                raise ValueError('A0GL CRC mismatch')
            mg,version,kind,seq,dropped,good,bad,aborted,reserved=struct.unpack('<4sBBHIIIII',blob[:28])
            if version!=1 or kind!=1 or reserved!=0 or dropped==0:
                raise ValueError('invalid A0GL fields')
            frames.append({'kind':'loss_notice','sequence':seq,'dropped':dropped,
                           'good':good,'bad':bad,'aborted':aborted})
        i+=n
    return frames

def audit_loss_notices(data, *, final_dropped=None):
    """Fail closed on malformed/nonmonotone reports; final count is EXTERNAL.
    No packet proves physical provenance. Dropped count is cumulative/saturating.
    """
    rows=decode_p118_stream(data)
    notices=[r for r in rows if r['kind']=='loss_notice']
    prev=0
    for row in rows:
        if row['kind'] in ('loss_notice','frame'):
            if row['dropped']<prev: raise ValueError('telemetry dropped count regressed')
            prev=row['dropped']
    if final_dropped is not None:
        if not _u32(final_dropped): raise ValueError('invalid final counter')
        if prev!=final_dropped: raise ValueError('final loss counter not witnessed')
        if final_dropped and not notices: raise ValueError('loss notice absent')
    return {'records':len(rows),'notices':len(notices),'last_witnessed_drops':prev,
            'physical_hardware_verified':False}

@dataclass(frozen=True)
class LossEdge:
    valid:bool
    byte:int|None
    emitted:bool
    frame_accepted:bool
    notice_enqueued:bool
    dropped:bool
    count_before:int

class LossTelemetryFifoSpec:
    def __init__(self,depth=4):
        if type(depth) is not int or depth<2:raise ValueError('depth must be int >=2')
        self.depth=depth;self.reset()
    def reset(self):
        self.queue=deque();self.offset=0;self.sequence=0;self.dropped=0;self.notice_owed=False
    def tick(self,*,frame_valid=False,error=False,frame_crc=0,good=0,bad=0,aborted=0,tx_ready=False,rst_n=True):
        if not rst_n:
            self.reset();return LossEdge(False,None,False,False,False,False,0)
        before=len(self.queue)
        valid=before>0
        byte=self.queue[0][self.offset] if valid else None
        emit=bool(valid and tx_ready)
        pop=emit and self.offset==31
        slot=before<self.depth or pop
        notice=bool(self.notice_owed and slot)
        frame=bool(frame_valid and slot and not self.notice_owed)
        drop=bool(frame_valid and not frame)
        packet=None
        if notice:
            packet=encode_loss_notice(sequence=self.sequence,dropped=self.dropped,
                                      good=good,bad=bad,aborted=aborted)
        elif frame:
            packet=encode_frame(sequence=self.sequence,error=bool(error),frame_crc=frame_crc,
                                good=good,bad=bad,aborted=aborted,dropped=self.dropped)
        if frame_valid:self.sequence=(self.sequence+1)&0xffff
        if drop:self.dropped=min(self.dropped+1,0xffffffff)
        if drop:self.notice_owed=True
        elif notice:self.notice_owed=False
        if emit:
            if pop:self.queue.popleft();self.offset=0
            else:self.offset+=1
        if packet is not None:self.queue.append(packet)
        assert len(self.queue)<=self.depth
        return LossEdge(valid,byte,emit,frame,notice,drop,before)
