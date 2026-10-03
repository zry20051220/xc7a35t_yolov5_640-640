"""Receive the FPGA's first-layer output CRC diagnostic packet."""

import argparse
import socket

import numpy as np
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=6102)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.bind, args.port))
        sock.settimeout(args.timeout)
        print(f"waiting for FPGA CRC on UDP {args.bind}:{args.port}")
        try:
            payload, address = sock.recvfrom(2048)
        except TimeoutError:
            raise SystemExit("timeout: no FPGA CRC packet received")
    if len(payload) not in (8, 40) or payload[:4] != b"CRC1":
        raise SystemExit(f"unexpected packet from {address}: {payload.hex()}")
    actual = int.from_bytes(payload[4:8], "big")
    expected = 0x1EA472BA
    print(f"FPGA output crc32={actual:08x} expected={expected:08x} "
          f"match={actual == expected}")
    if len(payload) == 40:
        root = Path(__file__).resolve().parents[2]
        golden = np.load(root / "work/model_extract/yolov5-v6.1-pytorch-master/npy/img_conv1.int.npy",
                         allow_pickle=False)[0].tobytes()[:32]
        sample = payload[8:]
        mismatches = [i for i, (got, want) in enumerate(zip(sample, golden))
                      if got != want]
        print(f"FPGA first32={sample.hex()}")
        print(f"gold first32={golden.hex()}")
        print(f"first32 mismatches={len(mismatches)} positions={mismatches}")


if __name__ == "__main__":
    main()
