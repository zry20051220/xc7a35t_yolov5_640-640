import argparse
import math
import socket
import time
import cv2
import json
from pathlib import Path
from eth_protocol import build_image_packet
from preprocess import letterbox_bgr_to_rgb
from model_input import quantized_focus_bgr

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('image'); ap.add_argument('--ip',default='192.168.0.2')
    ap.add_argument('--port',type=int,default=5000); ap.add_argument('--frame-id',type=int,default=1)
    ap.add_argument('--model-input', action='store_true',
                    help='send quantized Focus tensor for the first convolution')
    args=ap.parse_args()
    image=cv2.imread(args.image)
    if image is None: raise SystemExit('cannot read image')
    if args.model_input:
        manifest_path = Path(__file__).resolve().parents[2] / 'weights' / 'yolov5n_int8_manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        raw = quantized_focus_bgr(image, manifest['layers'][0]['input_scale']).tobytes()
    else:
        rgb,_,_=letterbox_bgr_to_rgb(image)
        raw=rgb.tobytes()
    mtu=1400; count=math.ceil(len(raw)/mtu)
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    for i in range(count):
        payload=raw[i*mtu:(i+1)*mtu]
        pkt=build_image_packet(args.frame_id,640,640,i,count,payload,i==count-1)
        sock.sendto(pkt,(args.ip,args.port)); time.sleep(0.0002)
    print('sent frame',args.frame_id,'packets',count,'bytes',len(raw),
          'format', 'uint8-focus-chw' if args.model_input else 'rgb888-hwc')

if __name__=='__main__': main()
