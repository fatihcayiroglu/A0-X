"""P44 host binary interface driven by P43 SOFTWARE reference only.

No RTL was executed by these methods. No PCIe, DMA, GPU driver or hardware
claims. The simulated device accepts ONE command at a time and retains tags.
"""
import hashlib
import struct
import zlib
from a0_graphics_pipeline_p43 import P43SoftwareAdapter
from a0_host_protocol_p44 import (CommandStreamDecoder, Result, SUCCESS,
                                  COMMAND_ERROR, TIMEOUT, encode_result)

class P44SoftwareDevice:
    def __init__(self, width: int, height: int, *, max_cycles=None):
        if type(width) is not int or type(height) is not int or not 1 <= width <= 32767 or not 1 <= height <= 32767 or width * height > 65536:
            raise ValueError('resolution must be positive with at most 65536 pixels')
        self.width, self.height = width, height
        self.adapter = P43SoftwareAdapter(width, height)
        self.decoder = CommandStreamDecoder()
        self.max_cycles = max_cycles if max_cycles is not None else 6 * width * height + 128
        if type(self.max_cycles) is not int or not 1 <= self.max_cycles <= 0xffffffff:
            raise ValueError('invalid cycle deadline')
        self.results = []

    def execute(self, command):
        # Only called after the binary command passed CRC and canonical checks.
        # Pre-clock state determines handshake on this simulation tick.
        for i in range(self.max_cycles):
            before, _ = self.adapter.step(command if i == 0 else None,
                                          scan_enable=False, completion_ready=True)
            if before.completion_valid:
                if before.completion_tag != command.tag:
                    raise RuntimeError('tag conservation violated in reference')
                return Result(COMMAND_ERROR if before.completion_error else SUCCESS,
                              before.completion_tag, i+1)
        # A stalled command leaves reference state busy. This model refuses
        # further commands after TIMEOUT (device loss / reset required).
        self.lost = True
        return Result(TIMEOUT, command.tag, self.max_cycles)

    def receive(self, payload: bytes) -> bytes:
        if getattr(self, 'lost', False):
            raise RuntimeError('device timed out; reset required')
        responses = []
        for command in self.decoder.feed(payload):
            result = self.execute(command)
            self.results.append(result)
            responses.append(encode_result(result))
            if result.status == TIMEOUT:
                break
        return b''.join(responses)

    def visible_rgb(self) -> bytes:
        if not self.adapter.display.display_initialized:
            raise RuntimeError('no PRESENTed/initialized visible framebuffer')
        cells = self.adapter.display.banks[self.adapter.display.front].cells
        if any(type(c) is not int or not 0 <= c <= 0xffffff for c in cells):
            raise RuntimeError('visible image is not fully initialized')
        return b''.join(c.to_bytes(3, 'big') for c in cells)

    def image_digest(self):
        return hashlib.sha256(self.visible_rgb()).hexdigest()

def png_rgb(width, height, pixels: bytes) -> bytes:
    if len(pixels) != width * height * 3:
        raise ValueError('incorrect RGB image size')
    def chunk(name, body):
        data = name + body
        return struct.pack('>I', len(body)) + data + struct.pack('>I', zlib.crc32(data)&0xffffffff)
    scanlines = b''.join(b'\x00' + pixels[y*width*3:(y+1)*width*3] for y in range(height))
    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(scanlines, 9)) + chunk(b'IEND', b''))
