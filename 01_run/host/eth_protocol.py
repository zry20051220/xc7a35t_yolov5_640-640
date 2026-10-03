import binascii
import struct

MAGIC = b"YOLO"
VERSION = 1
TYPE_IMAGE = 0x01
TYPE_WEIGHTS = 0x02
HEADER = struct.Struct("!4sBBIHHBBHHHH")

def build_data_packet(msg_type, frame_id, width, height, packet_index,
                      total_packets, payload, final=False, row_or_line=0):
    if msg_type not in (TYPE_IMAGE, TYPE_WEIGHTS):
        raise ValueError("unsupported message type")
    if len(payload) > 1400:
        raise ValueError("payload exceeds 1400 bytes")
    flags = 1 if final else 0
    header = HEADER.pack(MAGIC, VERSION, msg_type, frame_id, width, height,
                         0, flags, total_packets, packet_index, row_or_line,
                         len(payload))
    body = header + payload
    return body + struct.pack("!I", binascii.crc32(body) & 0xffffffff)

def build_image_packet(frame_id, width, height, packet_index, total_packets,
                       payload, final=False, row_or_line=0):
    return build_data_packet(TYPE_IMAGE, frame_id, width, height, packet_index,
                             total_packets, payload, final, row_or_line)

def build_weight_packet(frame_id, packet_index, total_packets, payload,
                        final=False):
    return build_data_packet(TYPE_WEIGHTS, frame_id, 640, 640, packet_index,
                             total_packets, payload, final)

def validate_packet(packet):
    if len(packet) < HEADER.size + 4:
        return False
    body, expected = packet[:-4], struct.unpack("!I", packet[-4:])[0]
    return (binascii.crc32(body) & 0xffffffff) == expected
