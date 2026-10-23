"""P114 independent scanout lifecycle oracle (intent, not cycle-verified RTL)."""
from __future__ import annotations
from dataclasses import dataclass

MAX32=(1<<32)-1
@dataclass(frozen=True)
class Snapshot:
    state:str
    expected_index:int
    age:int
    done_age:int
    timed_out:int
    protocol_faults:int
    completed:int
    accepted_pixels:int
    stalled_cycles:int
    fault_x:int
    fault_y:int

class ScanoutLiveness:
    def __init__(self,width:int=8,height:int=8,max_idle:int=4096,done_delay:int=4):
        for name,value,limit in [('width',width,32767),('height',height,32767),
                                  ('max_idle',max_idle,0x7fffffff),('done_delay',done_delay,0x7fffffff)]:
            if type(value) is not int or not 1 <= value <= limit:
                raise ValueError(f'{name} out of range')
        if width*height>65536:raise ValueError('frame exceeds addressable pixels')
        self.width=width;self.height=height;self.max_idle=max_idle;self.done_delay=done_delay
        self.reset()

    def reset(self):
        self.state='IDLE';self.idx=0;self.age=0;self.done_age=0
        self.held=None;self.timed_out=0;self.protocol_faults=0
        self.completed=0;self.accepted_pixels=0;self.stalled_cycles=0
        self.fault_x=0;self.fault_y=0
        return self.snapshot()

    def snapshot(self):
        return Snapshot(self.state,self.idx,self.age,self.done_age,self.timed_out,
                        self.protocol_faults,self.completed,self.accepted_pixels,
                        self.stalled_cycles,self.fault_x,self.fault_y)

    def fault(self,kind,x,y):
        setattr(self,kind,min(MAX32,getattr(self,kind)+1))
        self.fault_x=x;self.fault_y=y;self.state='FAULT'

    def tick(self,*,active=False,valid=False,ready=False,x=0,y=0,color=0,
             sof=False,eol=False,eof=False,done=False):
        for value in (active,valid,ready,sof,eol,eof,done):
            if type(value) is not bool:raise ValueError('control flags must be bool')
        for name,value,limit in [('x',x,0xffff),('y',y,0xffff),('color',color,0xffffff)]:
            if type(value) is not int or not 0<=value<=limit:raise ValueError(f'{name} out of range')
        payload=(x,y,color,sof,eol,eof)
        if self.state=='IDLE':
            if done or valid:
                self.fault('protocol_faults',x,y)
            elif active:
                self.state='STREAM';self.idx=0;self.age=0;self.done_age=0;self.held=None
        elif self.state=='STREAM':
            if not active or done or (self.held is not None and (not valid or payload!=self.held)):
                self.fault('protocol_faults',x,y)
            elif valid and ready:
                ex=self.idx%self.width;ey=self.idx//self.width
                expected=(ex,ey,ex==0 and ey==0,ex==self.width-1,
                          self.idx==self.width*self.height-1)
                if (x,y,sof,eol,eof)!=expected:
                    self.fault('protocol_faults',x,y)
                else:
                    self.accepted_pixels=min(MAX32,self.accepted_pixels+1)
                    self.held=None;self.age=0
                    if self.idx==self.width*self.height-1:
                        self.state='WAIT_DONE';self.done_age=0
                    else:self.idx+=1
            elif valid and not ready:
                if self.held is None:self.held=payload
                self.stalled_cycles=min(MAX32,self.stalled_cycles+1)
            elif self.age>=self.max_idle-1:
                self.fault('timed_out',self.idx%self.width,self.idx//self.width)
            else:self.age+=1
        elif self.state=='WAIT_DONE':
            if not active or valid:
                self.fault('protocol_faults',x,y)
            elif done:
                self.completed=min(MAX32,self.completed+1);self.state='IDLE'
            elif self.done_age>=self.done_delay-1:
                self.fault('timed_out',self.width-1,self.height-1)
            else:self.done_age+=1
        return self.snapshot()

    def pixel(self,index:int,color:int=0,ready:bool=True):
        """Convenience to construct one exact beat for a test."""
        x=index%self.width;y=index//self.width
        return self.tick(active=True,valid=True,ready=ready,x=x,y=y,color=color,
                         sof=index==0,eol=x==self.width-1,
                         eof=index==self.width*self.height-1)
