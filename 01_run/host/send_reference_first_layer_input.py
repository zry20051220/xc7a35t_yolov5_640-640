"""Send the supplied 12x320x320 quantized tensor used by the conv1 golden CRC."""

import argparse
import binascii
import json
import math
import socket
import time
from pathlib import Path

import numpy as np

from eth_protocol import build_image_packet


ROOT = Path(__file__).resolve().parents[2]
INPUT_NPY = ROOT / "work/model_extract/yolov5-v6.1-pytorch-master/npy/img.int.npy"
LAUNCH = ROOT / "outputs/first_layer_launch.json"


def reference_payload() -> bytes:
    config = json.loads(LAUNCH.read_text(encoding="utf-8"))
    tensor = np.load(INPUT_NPY, allow_pickle=False)
    assert tensor.shape == (1, 12, 320, 320), tensor.shape
    assert tensor.dtype == np.uint8, tensor.dtype
    payload = np.ascontiguousarray(tensor[0]).tobytes()
    assert len(payload) == config["ddr_regions"]["input"]["bytes"]
    actual_crc = f"{binascii.crc32(payload):08x}"
    assert actual_crc == config["reference"]["input"]["crc32"], actual_crc
    return payload


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.0.2")
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--frame-id", type=int, default=207)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    payload = reference_payload()
    mtu = 1400
    count = math.ceil(len(payload) / mtu)
    if not args.dry_run:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            for index in range(count):
                part = payload[index * mtu:(index + 1) * mtu]
                packet = build_image_packet(args.frame_id, 640, 640, index,
                                            count, part, index == count - 1)
                sock.sendto(packet, (args.ip, args.port))
                time.sleep(0.0002)
    action = "prepared" if args.dry_run else "sent"
    print(f"{action} reference input frame {args.frame_id}: {count} packets, "
          f"{len(payload)} bytes, crc32={binascii.crc32(payload):08x}")


if __name__ == "__main__":
    main()
