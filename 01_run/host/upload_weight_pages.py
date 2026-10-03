"""Upload up to three DDR pages, requiring the FPGA CRC acknowledgement."""
import argparse
import socket
import time
import zlib
from pathlib import Path
from eth_protocol import build_weight_packet


FRAME_BYTES = 640*640*3


def weight_pages(data, frame_id):
    # A fourth padded page would overlap features beginning at DDR 0x800000.
    if not 0 < len(data) <= 3*FRAME_BYTES:
        raise ValueError('weights must fit three pages before the feature buffers')
    if not 0 <= frame_id < (1 << 24):
        raise ValueError('frame id must fit 24 bits; high bits encode page')
    for page, start in enumerate(range(0, len(data), FRAME_BYTES)):
        yield page, (page << 24) | frame_id, data[start:start+FRAME_BYTES].ljust(FRAME_BYTES, b'\0')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('blob', type=Path)
    parser.add_argument('--frame-id', type=int, default=247)
    parser.add_argument('--host-ip', default='192.168.0.3')
    parser.add_argument('--fpga-ip', default='192.168.0.2')
    parser.add_argument('--timeout', type=float, default=30)
    args = parser.parse_args()
    data = args.blob.read_bytes()
    pages = list(weight_pages(data, args.frame_id))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
        receiver.bind((args.host_ip, 6102))
        receiver.settimeout(args.timeout)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
            sender.bind((args.host_ip, 0))
            for page, frame, part in pages:
                count = (len(part)+1399)//1400
                for index in range(count):
                    packet = build_weight_packet(frame, index, count, part[index*1400:(index+1)*1400], index == count-1)
                    sender.sendto(packet, (args.fpga_ip, 5000))
                    time.sleep(0.0002)
                expected = zlib.crc32(part)
                try:
                    result, _ = receiver.recvfrom(2048)
                except TimeoutError:
                    raise SystemExit(f'page {page}: FPGA acknowledgement timeout; weights not verified')
                if len(result) < 8 or result[:4] != b'WGT1':
                    raise SystemExit(f'unexpected weight acknowledgement: {result.hex()}')
                actual = int.from_bytes(result[4:8], 'big')
                print(f'page={page} crc32={actual:08x} expected={expected:08x} match={actual == expected}', flush=True)
                if actual != expected:
                    raise SystemExit(1)
    print('all weight pages verified')


if __name__ == '__main__':
    main()
