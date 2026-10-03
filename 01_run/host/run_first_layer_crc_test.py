"""Atomically listen, send the golden input, and receive the FPGA CRC."""

import argparse
import binascii
import math
import socket
import time

import numpy as np
from pathlib import Path

from eth_protocol import build_image_packet
from send_reference_first_layer_input import reference_payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fpga-ip", default="192.168.0.2")
    parser.add_argument("--host-ip", default="192.168.0.3")
    parser.add_argument("--input-port", type=int, default=5000)
    parser.add_argument("--result-port", type=int, default=6102)
    parser.add_argument("--frame-id", type=int, default=218)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--layers", type=int, choices=(1, 2, 4, 6, 7, 15, 25, 32, 60), default=1)
    parser.add_argument("--read-layer", type=int, choices=(1, 2, 3, 4, 5, 6, 7, 15, 25, 32))
    args = parser.parse_args()

    payload = reference_payload()
    mtu = 1400
    count = math.ceil(len(payload) / mtu)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
        receiver.bind((args.host_ip, args.result_port))
        receiver.settimeout(args.timeout)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
            sender.bind((args.host_ip, 0))
            for index in range(count):
                part = payload[index * mtu:(index + 1) * mtu]
                packet = build_image_packet(args.frame_id, 640, 640, index,
                                            count, part, index == count - 1)
                sender.sendto(packet, (args.fpga_ip, args.input_port))
                time.sleep(0.0002)
        print(f"sent reference input frame {args.frame_id}: {count} packets, "
              f"crc32={binascii.crc32(payload):08x}; waiting for FPGA")
        try:
            result, address = receiver.recvfrom(2048)
        except TimeoutError:
            raise SystemExit("timeout: no FPGA CRC packet received")

    if len(result) not in (8, 40) or result[:4] != b"CRC1":
        raise SystemExit(f"unexpected packet from {address}: {result.hex()}")
    actual = int.from_bytes(result[4:8], "big")
    read_layer = args.read_layer or args.layers
    expected = {1: 0x1EA472BA, 2: 0x00F6993A, 3: 0x60FE2D2F,
                4: 0x3D042FD6, 5: 0x5BC7DAB7, 6: 0x3EE872F3,
                7: 0x847B1D7A, 15: 0x3AB8B0C0, 25: 0xA9B89D39, 32: 0xBCE1111A, 60: 0x675FF7F3}[read_layer]
    print(f"FPGA output crc32={actual:08x} expected={expected:08x} "
          f"match={actual == expected}")
    if len(result) == 40:
        root = Path(__file__).resolve().parents[2]
        output_name = 'out3' if read_layer == 60 else f'img_conv{read_layer}'
        golden = np.load(root / f"work/model_extract/yolov5-v6.1-pytorch-master/npy/{output_name}.int.npy",
                         allow_pickle=False)[0].tobytes()[:32]
        sample = result[8:]
        mismatches = [i for i, (got, want) in enumerate(zip(sample, golden))
                      if got != want]
        print(f"FPGA first32={sample.hex()}")
        print(f"gold first32={golden.hex()}")
        print(f"first32 mismatches={len(mismatches)} positions={mismatches}")
        if mismatches:
            raise SystemExit(1)
    if actual != expected:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
