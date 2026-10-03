"""Upload conv1 packed weights and bias to DDR 0x400000 as one padded frame."""

import argparse
import binascii
import json
import math
import socket
import time
from pathlib import Path

from eth_protocol import build_weight_packet


ROOT = Path(__file__).resolve().parents[2]
FRAME_BYTES = 640 * 640 * 3


def payload_bytes(layers: int = 1, high_precision: bool = False) -> tuple[bytes, int]:
    assert not high_precision or layers in (15, 25)
    manifest_path = f'weights/yolov5n_int8_qauto{layers}_manifest.json' if high_precision else 'weights/yolov5n_int8_manifest.json'
    manifest = json.loads((ROOT / manifest_path).read_text())
    assert layers in (1, 2, 4, 6, 7, 15, 25)
    assert layers != 25 or high_precision
    layer = manifest["layers"][layers - 1]
    assert manifest["layers"][0]["weight"]["offset"] == 0
    end = layer["bias"]["offset"] + layer["bias"]["bytes"]
    if 'add3_table' in manifest:
        table = manifest['add3_table']
        end = max(end, table['offset'] + table['bytes'])
    assert end <= FRAME_BYTES and end % 16 == 0
    blob_path = f'weights/yolov5n_int8_qauto{layers}.bin' if high_precision else 'weights/yolov5n_int8_weights.bin'
    blob = (ROOT / blob_path).read_bytes()
    assert len(blob) == manifest["blob_bytes"]
    return blob[:end] + bytes(FRAME_BYTES - end), end


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.0.2")
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--frame-id", type=int, default=200)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--high-precision", action="store_true")
    ap.add_argument("--layers", type=int, choices=(1, 2, 4, 6, 7, 15, 25), default=1)
    args = ap.parse_args()
    payload, useful = payload_bytes(args.layers, args.high_precision)
    mtu = 1400
    count = math.ceil(len(payload) / mtu)
    if not args.dry_run:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            for i in range(count):
                chunk = payload[i * mtu:(i + 1) * mtu]
                packet = build_weight_packet(args.frame_id, i, count, chunk,
                                             i == count - 1)
                sock.sendto(packet, (args.ip, args.port))
                time.sleep(0.0002)
    print(f"{'prepared' if args.dry_run else 'sent'} weight frame {args.frame_id}: "
          f"{count} packets, {len(payload)} bytes, useful={useful}, "
          f"crc32={binascii.crc32(payload):08x}, ddr_base=0x400000")


if __name__ == "__main__":
    main()
