"""Live preview with single-flight FPGA inference and a latest-frame queue.

Preview FPS and measured FPGA detection FPS are deliberately shown separately.
No software neural inference, golden tensors or queued old video frames.
"""
import argparse
import json
import math
import socket
import threading
import time
import zlib
from pathlib import Path
import cv2
import numpy as np
from decode_detections import decode_heads
from eth_protocol import build_image_packet
from model_input import quantized_focus_bgr, letterbox_bgr
from tensor_protocol import TensorAssembler

ROOT = Path(__file__).resolve().parents[2]


class FpgaDetector:
    def __init__(self, graph_path, host_ip='192.168.0.3', fpga_ip='192.168.0.2', timeout=30, packet_delay=.0002, confidence=None, nms_iou=None):
        if not math.isfinite(packet_delay) or not 0<=packet_delay<=.01:
            raise ValueError('packet delay must be 0..0.01 seconds')
        self.packet_delay=packet_delay
        self.graph = json.loads(Path(graph_path).read_text())
        self.size = self.graph.get('input_size', 640)
        self.letterbox = self.graph.get('preprocessing') == 'letterbox'
        self.heads = [self.graph['tensors'][name] for name in ('out1', 'out2', 'out3')]
        self.base = min(head['base'] for head in self.heads)
        self.span = max(head['base']+head['bytes'] for head in self.heads)-self.base
        first_conv=next(node for node in self.graph['nodes'] if node.get('op')=='conv')
        self.scale = first_conv['parameters']['input_scale']
        self.params = [next(node['parameters'] for node in self.graph['nodes'] if node['name']==name)
                       for name in ('out1','out2','out3')]
        model = ROOT/'work/model_extract/yolov5-v6.1-pytorch-master/model_data'
        self.anchors = (np.asarray(self.graph['anchors'],dtype=np.float32).reshape(-1)
                        if 'anchors' in self.graph else np.fromstring((model/'yolo_anchors.txt').read_text(),sep=','))
        self.labels = self.graph.get('classes') or (model/'voc_classes.txt').read_text().splitlines()
        if len(self.labels)!=self.heads[0]['shape'][1]//3-5:
            raise ValueError('Graph labels do not match detection head channels')
        self.confidence = (.3 if self.size==640 else .2) if self.labels==['head'] else .5
        self.nms_iou = (.35 if self.size==640 else .45) if self.labels==['head'] else .3
        if confidence is not None: self.confidence=confidence
        if nms_iou is not None: self.nms_iou=nms_iou
        if not all(math.isfinite(value) and 0<value<1 for value in (self.confidence,self.nms_iou)):
            raise ValueError('confidence and NMS IoU must be finite and strictly between 0 and 1')
        self.fpga_ip, self.timeout = fpga_ip, timeout
        self.rx = socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        try:
            self.rx.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024)
            self.rx.bind((host_ip,6102))
            self.tx = socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            self.tx.bind((host_ip,0))
        except Exception:
            self.rx.close()
            if hasattr(self,'tx'):self.tx.close()
            raise

    def close(self):
        self.rx.close();self.tx.close()

    def detect(self,image,frame_id):
        started=time.monotonic()
        payload=quantized_focus_bgr(image,self.scale,self.size,self.letterbox).tobytes()
        prepared=time.monotonic()
        count=math.ceil(len(payload)/1400)
        assembler=TensorAssembler(frame_id,self.span)
        for index in range(count):
            self.tx.sendto(build_image_packet(frame_id,self.size,self.size,index,count,
                payload[index*1400:(index+1)*1400],index==count-1),(self.fpga_ip,5000))
            if self.packet_delay:time.sleep(self.packet_delay)
        sent=time.monotonic()
        deadline=started+self.timeout
        while not assembler.complete:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise TimeoutError(f'FPGA frame {frame_id}: {len(assembler.received)}/{assembler.expected_blocks} blocks')
            self.rx.settimeout(min(remaining,1))
            try:packet,source=self.rx.recvfrom(2048)
            except socket.timeout:continue
            if source[0]!=self.fpga_ip or packet[:4]!=b'DAT1':continue
            # Late packets from an earlier run cannot enter the current tensor.
            if len(packet)<16 or int.from_bytes(packet[4:8],'big')!=frame_id:continue
            assembler.accept(packet)
        received=time.monotonic()
        tensors=[np.frombuffer(assembler.data,dtype=np.uint8,count=head['bytes'],
                              offset=head['base']-self.base).reshape(head['shape'][1:]) for head in self.heads]
        self.last_heads=[tensor.copy() for tensor in tensors]
        self.last_head_crc32={name:f'{zlib.crc32(tensor.tobytes()):08x}'
                             for name,tensor in zip(('out1','out2','out3'),tensors)}
        geometry=letterbox_bgr(image,self.size)[1] if self.letterbox else None
        boxes=decode_heads(tensors,self.params,self.anchors,image.shape,confidence=self.confidence,
                           nms_iou=self.nms_iou,input_size=self.size,letterbox=geometry)
        finished=time.monotonic()
        self.last_stage_seconds=dict(preprocess=prepared-started,input_send=sent-prepared,
            fpga_and_head_receive=received-sent,head_unpack_and_decode=finished-received)
        return boxes,finished-started


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',default='0',help='USB camera number or local video path')
    parser.add_argument('--graph',type=Path,required=True,help='must match programmed and validated bit')
    parser.add_argument('--frame-id',type=int,default=10000)
    parser.add_argument('--timeout',type=float,default=30)
    parser.add_argument('--packet-delay',type=float,default=.0002)
    parser.add_argument('--confidence',type=float)
    parser.add_argument('--nms-iou',type=float)
    args=parser.parse_args()
    detector=FpgaDetector(args.graph,timeout=args.timeout,packet_delay=args.packet_delay,
                          confidence=args.confidence,nms_iou=args.nms_iou)
    source=int(args.source) if args.source.isdigit() else args.source
    capture=cv2.VideoCapture(source)
    if not capture.isOpened():
        detector.close();capture.release();raise SystemExit('cannot open camera/video')
    capture.set(cv2.CAP_PROP_BUFFERSIZE,1)
    file_fps=capture.get(cv2.CAP_PROP_FPS)
    if not 1 <= file_fps <= 240:file_fps=30
    next_video_frame=time.monotonic()
    lock=threading.Lock();stop=threading.Event()
    state=dict(latest=None,sequence=0,result=None,error=None)
    def worker():
        consumed=-1;frame_id=args.frame_id;finished_times=[]
        while not stop.is_set():
            with lock:
                frame=state['latest'];sequence=state['sequence']
            if frame is None or sequence==consumed:
                stop.wait(.01);continue
            consumed=sequence
            try:
                boxes,elapsed=detector.detect(frame,frame_id)
                finished=time.monotonic();finished_times.append(finished)
                finished_times=finished_times[-20:]
                cadence=(len(finished_times)-1)/(finished_times[-1]-finished_times[0]) if len(finished_times)>1 else 0
                with lock:state['result']=(boxes,elapsed,finished,frame.shape,frame_id,cadence)
                print(f'FPGA frame={frame_id} end-to-end={elapsed:.3f}s detection={1/elapsed:.3f}FPS',flush=True)
                frame_id+=1
            except Exception as error:
                if not stop.is_set():
                    with lock:state['error']=str(error)
                break # Do not retry into an unknown half-frame/busy board state.
    thread=threading.Thread(target=worker,daemon=True);thread.start()
    previous=time.monotonic();preview_fps=0
    try:
        while True:
            if not isinstance(source,int):
                stop.wait(max(0,next_video_frame-time.monotonic()))
                next_video_frame+=1/file_fps
            ok,image=capture.read()
            if not ok:break
            now=time.monotonic();preview_fps=.9*preview_fps+.1/max(now-previous,1e-6);previous=now
            with lock:
                state['latest']=image.copy();state['sequence']+=1
                result=state['result'];error=state['error']
            detection='FPGA: waiting'
            if result:
                boxes,elapsed,finished,shape,frame_id,cadence=result
                age=now-finished+elapsed
                detection=f'FPGA: {cadence:.2f} FPS  box age: {age:.1f}s'
                # Suppress stale overlays and overlays with changed video geometry.
                if age<=max(2,elapsed*2) and shape==image.shape:
                    if detector.labels==['head']:
                        detection+=f' | Heads: {len(boxes)}'
                    for x1,y1,x2,y2,score,category in boxes:
                        cv2.rectangle(image,(round(x1),round(y1)),(round(x2),round(y2)),(0,255,0),2)
                        cv2.putText(image,f'{detector.labels[int(category)]} {score:.2f}',
                            (round(x1),max(18,round(y1)-4)),cv2.FONT_HERSHEY_SIMPLEX,.5,(0,255,0),1)
            cv2.putText(image,f'Preview: {preview_fps:.1f} FPS | {detection}',(10,22),
                        cv2.FONT_HERSHEY_SIMPLEX,.5,(0,255,255),1)
            if error:cv2.putText(image,'FPGA stopped: '+error[:70],(10,44),cv2.FONT_HERSHEY_SIMPLEX,.5,(0,0,255),1)
            cv2.imshow('ACX720 FPGA detection - Q to quit',image)
            if cv2.waitKey(1)&255 in (27,ord('q')):break
    finally:
        stop.set();detector.close();thread.join(timeout=2)
        capture.release();cv2.destroyAllWindows()


if __name__=='__main__':main()
