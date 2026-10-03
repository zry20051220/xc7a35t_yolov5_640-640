"""Send quantized image input, receive complete FPGA heads, then decode on PC."""
import argparse
import json
import math
import socket
import subprocess
import sys
import time
import zlib
from pathlib import Path
import cv2
import numpy as np
from eth_protocol import build_image_packet
from model_input import quantized_focus_bgr
from send_reference_first_layer_input import reference_payload
from tensor_protocol import TensorAssembler


ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--reference', action='store_true')
    source.add_argument('--image', type=Path)
    parser.add_argument('--frame-id', type=int, default=252)
    parser.add_argument('--host-ip', default='192.168.0.3')
    parser.add_argument('--fpga-ip', default='192.168.0.2')
    parser.add_argument('--timeout', type=float, default=900)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--graph', type=Path, default=ROOT/'outputs/network_graph.json',
                        help='must match the bitstream actually programmed')
    parser.add_argument('--expected-dir', type=Path, help='offline oracle for numerical acceptance only')
    args = parser.parse_args()
    total_began = time.monotonic()
    graph = json.loads(args.graph.read_text())
    input_size = graph.get('input_size', 640)
    use_letterbox = graph.get('preprocessing') == 'letterbox'
    if args.reference and input_size != 640:
        raise SystemExit('320 reference is not generated; do not reuse 640 golden tensors')
    heads = {name: graph['tensors'][name] for name in ('out1', 'out2', 'out3')}
    base = min(info['base'] for info in heads.values())
    end = max(info['base']+info['bytes'] for info in heads.values())
    assembler = TensorAssembler(args.frame_id, end-base)
    output = args.output or ROOT/f'outputs/board_heads_frame{args.frame_id}'
    def fail_capture(reason):
        output.mkdir(parents=True, exist_ok=True)
        (output/'tensor_region.partial.bin').write_bytes(assembler.data)
        report = dict(frame_id=args.frame_id, complete=False, received_blocks=len(assembler.received),
                      expected_blocks=assembler.expected_blocks, received_offsets=sorted(assembler.received),
                      missing_offsets=assembler.missing_offsets(), reason=reason)
        (output/'partial_capture.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        raise SystemExit(f'{reason}; received={len(assembler.received)}/{assembler.expected_blocks}; '
                         f'diagnostics={output}; no detection produced')
    if args.reference:
        payload = reference_payload()
    else:
        image = cv2.imdecode(np.fromfile(args.image, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise SystemExit('cannot read input image')
        manifest = json.loads((ROOT/'weights/yolov5n_int8_qauto60_manifest.json').read_text())
        payload = quantized_focus_bgr(image, manifest['layers'][0]['input_scale'],
                                      input_size, use_letterbox).tobytes()
    if len(payload) != graph['tensors']['img']['bytes']:
        raise SystemExit('incorrect Focus input size')
    if args.expected_dir:
        expected_input = np.load(args.expected_dir/'img.npy', allow_pickle=False)
        if expected_input.dtype != np.uint8 or expected_input.tobytes() != payload:
            raise SystemExit('offline oracle input differs from transmitted image')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
        receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4*1024*1024)
        receiver.bind((args.host_ip, 6102))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
            sender.bind((args.host_ip, 0))
            count = math.ceil(len(payload)/1400)
            for index in range(count):
                part = payload[index*1400:(index+1)*1400]
                sender.sendto(build_image_packet(args.frame_id, input_size, input_size, index, count, part,
                                                 index==count-1), (args.fpga_ip, 5000))
                time.sleep(.0002)
        began = time.monotonic()
        deadline = began+args.timeout
        print(f'input frame={args.frame_id} crc32={zlib.crc32(payload):08x}; waiting for complete FPGA heads', flush=True)
        while not assembler.complete:
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                fail_capture('tensor timeout')
            receiver.settimeout(min(remaining, 30))
            try:
                packet, address = receiver.recvfrom(2048)
            except TimeoutError:
                if assembler.received:
                    fail_capture(f'incomplete tensor stream: missing offsets {assembler.missing_offsets()[:12]}')
                continue
            if address[0] != args.fpga_ip or packet[:4] != b'DAT1':
                continue
            try:
                assembler.accept(packet)
            except ValueError as error:
                fail_capture(str(error))
            if len(assembler.received) == 1:
                print('first FPGA tensor block received', flush=True)
            elif len(assembler.received) % 256 == 0:
                print(f'FPGA tensor blocks={len(assembler.received)}/{assembler.expected_blocks}', flush=True)
        elapsed = time.monotonic()-began
    output.mkdir(parents=True, exist_ok=True)
    statistics = dict(source='FPGA DAT1 stream', frame_id=args.frame_id, elapsed_seconds=elapsed,
                      input_size=input_size, preprocessing='letterbox' if use_letterbox else 'direct_resize',
                      graph=str(args.graph.resolve()),
                      received_blocks=len(assembler.received), complete=True, heads={})
    failed = False
    for name, info in heads.items():
        offset = info['base']-base
        actual = bytes(assembler.data[offset:offset+info['bytes']])
        (output/f'{name}.bin').write_bytes(actual)
        result = dict(bytes=len(actual), crc32=f'{zlib.crc32(actual):08x}')
        if args.reference:
            gold = np.load(ROOT/f'work/model_extract/yolov5-v6.1-pytorch-master/npy/{name}.int.npy')[0].tobytes()
            result.update(golden_crc32=info['crc32'], mismatches=sum(a!=b for a,b in zip(actual, gold)))
            failed |= result['mismatches'] != 0
        if args.expected_dir:
            expected = np.load(args.expected_dir/f'{name}.npy', allow_pickle=False)
            if expected.dtype != np.uint8 or list(expected.shape) != info['shape'][1:]:
                raise SystemExit(f'{name}: offline oracle shape/dtype mismatch')
            result['mismatches'] = int(np.count_nonzero(np.frombuffer(actual, dtype=np.uint8).reshape(expected.shape) != expected))
            failed |= result['mismatches'] != 0
        statistics['heads'][name] = result
        print(f'{name}: {result}', flush=True)
    (output/'capture.json').write_text(json.dumps(statistics, indent=2), encoding='utf-8')
    print(f'complete FPGA capture: {output}; elapsed={elapsed:.2f}s', flush=True)
    if failed:
        raise SystemExit('reference mismatch; raw heads retained for diagnosis')
    if args.image:
        subprocess.run([sys.executable, str(ROOT/'sw/host/decode_detections.py'), str(output),
                        '--image', str(args.image), '--output', str(output/'detections.png'),
                        '--graph', str(args.graph)], check=True)
    total_elapsed = time.monotonic()-total_began
    statistics.update(end_to_end_seconds=total_elapsed, end_to_end_fps=1/total_elapsed)
    (output/'capture.json').write_text(json.dumps(statistics, indent=2), encoding='utf-8')
    print(f'end-to-end FPGA detection: {total_elapsed:.3f}s ({1/total_elapsed:.4f} FPS)', flush=True)


if __name__ == '__main__':
    main()
