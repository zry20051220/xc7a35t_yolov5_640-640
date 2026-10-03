import json
import tempfile
import unittest
import zlib
import struct
from pathlib import Path
from unittest.mock import patch
import numpy as np
import live_detector
from eth_protocol import HEADER, validate_packet


class FakeSocket:
    def __init__(self, packets=()):
        self.packets=list(packets);self.sent=[];self.closed=False
    def setsockopt(self,*args):pass
    def bind(self,*args):pass
    def settimeout(self,*args):pass
    def sendto(self,data,address):self.sent.append(data)
    def recvfrom(self,*args):return self.packets.pop(0),('192.168.0.2',5000)
    def close(self):self.closed=True


class LiveDetectorTest(unittest.TestCase):
    def test_invalid_packet_delay_rejected_before_opening_sockets(self):
        for delay in (-1,float('nan'),float('inf'),.02):
            with self.subTest(delay=delay),patch.object(live_detector.socket,'socket') as socket_factory:
                with self.assertRaises(ValueError):live_detector.FpgaDetector('missing.json',packet_delay=delay)
                socket_factory.assert_not_called()

    def test_persistent_receiver_complete_heads_and_320_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'weights').mkdir()
            (root/'weights/yolov5n_int8_qauto60_manifest.json').write_text(json.dumps(
                {'layers':[{'input_scale':1/255}]}))
            model=root/'work/model_extract/yolov5-v6.1-pytorch-master/model_data'
            model.mkdir(parents=True)
            (model/'yolo_anchors.txt').write_text(','.join(['10','13']*9))
            (model/'voc_classes.txt').write_text('\n'.join('class'+str(i) for i in range(20)))
            tensors={};nodes=[dict(name='img_conv1',op='conv',parameters=dict(input_scale=1/255))];cursor=0
            for name,size in zip(('out1','out2','out3'),(10,20,40)):
                count=75*size*size
                tensors[name]=dict(base=cursor,bytes=count,shape=[1,75,size,size]);cursor+=count
                nodes.append(dict(name=name,parameters=dict(output_scale=1,output_zero_point=128)))
            graph=root/'graph.json'
            graph.write_text(json.dumps(dict(input_size=320,preprocessing='letterbox',tensors=tensors,nodes=nodes)))
            packets=[]
            for offset in range(0,cursor,512):
                data=bytes(min(512,cursor-offset))
                packets.append(struct.pack('!4sIII',b'DAT1',123,offset,zlib.crc32(data))+data)
            # A late packet from an earlier frame must be ignored, not mixed.
            packets.insert(0,struct.pack('!4sIII',b'DAT1',122,0,0)+bytes(512))
            rx,tx=FakeSocket(packets),FakeSocket()
            with patch.object(live_detector,'ROOT',root),patch.object(live_detector.socket,'socket',side_effect=[rx,tx]):
                client=live_detector.FpgaDetector(graph)
                boxes,elapsed=client.detect(np.zeros((240,640,3),dtype=np.uint8),123)
                self.assertEqual(boxes.shape,(0,6))
                self.assertGreater(elapsed,0)
                self.assertAlmostEqual(sum(client.last_stage_seconds.values()),elapsed)
                self.assertTrue(all(seconds>=0 for seconds in client.last_stage_seconds.values()))
                self.assertEqual(len(tx.sent),220)
                self.assertTrue(all(validate_packet(packet) for packet in tx.sent))
                self.assertEqual(HEADER.unpack(tx.sent[0][:HEADER.size])[3:6],(123,320,320))
                self.assertEqual(HEADER.unpack(tx.sent[-1][:HEADER.size])[7],1)
                client.close()
                self.assertTrue(rx.closed and tx.closed)

    def test_head_metadata_without_legacy_weights_or_labels(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); graph=root/'head.json'
            nodes=[dict(name='img_conv1',op='conv',parameters=dict(input_scale=.003))]
            tensors={}
            for index,size in enumerate((10,20,40),1):
                name=f'out{index}'
                tensors[name]=dict(base=index*100000,bytes=18*size*size,shape=[1,18,size,size])
                nodes.append(dict(name=name,op='conv',parameters=dict(output_scale=.1,output_zero_point=128)))
            graph.write_text(json.dumps(dict(tensors=tensors,nodes=nodes,input_size=320,
                                            classes=['head'],anchors=[[3,4]]*9)))
            rx,tx=FakeSocket(),FakeSocket()
            with patch.object(live_detector,'ROOT',root),patch.object(live_detector.socket,'socket',side_effect=[rx,tx]):
                client=live_detector.FpgaDetector(graph)
                self.assertEqual(client.labels,['head'])
                self.assertEqual(client.confidence,.2)
                self.assertEqual(client.scale,.003)
                self.assertEqual(client.anchors.shape,(18,))
                client.close()
            metadata=json.loads(graph.read_text()); metadata['input_size']=640
            graph.write_text(json.dumps(metadata))
            with patch.object(live_detector.socket,'socket',side_effect=[FakeSocket(),FakeSocket()]):
                client=live_detector.FpgaDetector(graph)
                self.assertEqual(client.confidence,.3)
                self.assertEqual(client.nms_iou,.35)
                client.close()
            with patch.object(live_detector.socket,'socket',side_effect=[FakeSocket(),FakeSocket()]):
                client=live_detector.FpgaDetector(graph,confidence=.4,nms_iou=.35)
                self.assertEqual(client.confidence,.4)
                self.assertEqual(client.nms_iou,.35)
                client.close()
            with self.assertRaises(ValueError):
                live_detector.FpgaDetector(graph,confidence=float('nan'))


if __name__=='__main__':unittest.main()
