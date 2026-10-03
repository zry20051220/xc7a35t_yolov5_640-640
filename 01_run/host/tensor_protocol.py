"""Validate and reassemble DAT1 packets without accepting incomplete results."""
import struct
import zlib

HEADER = struct.Struct('!4sIII')
BLOCK_BYTES = 512


class TensorAssembler:
    def __init__(self, frame_id, total_bytes):
        if total_bytes <= 0:
            raise ValueError('invalid tensor region size')
        self.frame_id = frame_id
        self.total_bytes = total_bytes
        self.data = bytearray(total_bytes)
        self.received = set()
        self.expected_blocks = (total_bytes+BLOCK_BYTES-1)//BLOCK_BYTES

    @property
    def complete(self):
        return len(self.received) == self.expected_blocks

    def accept(self, packet):
        if len(packet) < HEADER.size:
            raise ValueError('short tensor packet')
        magic, frame, offset, crc = HEADER.unpack_from(packet)
        body = packet[HEADER.size:]
        if magic != b'DAT1' or frame != self.frame_id:
            raise ValueError('tensor magic or frame mismatch')
        if offset >= self.total_bytes or offset % BLOCK_BYTES:
            raise ValueError('unaligned or out-of-range tensor offset')
        expected_size = min(BLOCK_BYTES, self.total_bytes-offset)
        if len(body) != expected_size:
            raise ValueError('wrong tensor block length')
        if zlib.crc32(body) != crc:
            raise ValueError(f'tensor block CRC mismatch at offset {offset}')
        if offset in self.received and self.data[offset:offset+len(body)] != body:
            raise ValueError('conflicting duplicate tensor block')
        self.data[offset:offset+len(body)] = body
        self.received.add(offset)
        return self.complete

    def missing_offsets(self):
        return [offset for offset in range(0, self.total_bytes, BLOCK_BYTES)
                if offset not in self.received]
