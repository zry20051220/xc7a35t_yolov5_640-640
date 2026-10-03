import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from publish_realtime320 import check_evidence


class RealtimeReleaseTest(unittest.TestCase):
    def setUp(self):
        self.crcs=dict(out1='00000001',out2='00000002',out3='00000003')
        self.graph=dict(input_size=320,preprocessing='letterbox',tensors={
            'out1':dict(base=0,bytes=8),'out2':dict(base=8,bytes=16),'out3':dict(base=24,bytes=24)})
        self.capture=dict(source='FPGA DAT1 stream',complete=True,received_blocks=1,heads={
            name:dict(bytes=self.graph['tensors'][name]['bytes'],crc32=crc,mismatches=0)
            for name,crc in self.crcs.items()})
        self.benchmark=dict(source='persistent real FPGA path',frames=20,requested_frames=20,
            complete=True,seconds=13,fps=20/13,bit_sha256='BIT',graph_sha256='GRAPH',packet_delay_seconds=0,
            samples=[dict(frame_id=i,seconds=.6,head_crc32=copy.copy(self.crcs)) for i in range(20)])

    def check(self):
        return check_evidence(self.capture,self.benchmark,self.graph,'BIT','GRAPH')

    def test_valid_full_evidence(self):
        self.assertAlmostEqual(self.check(),20/13)

    def test_reject_incomplete_benchmark(self):
        self.benchmark['complete']=False
        with self.assertRaises(ValueError):self.check()

    def test_reject_sub_one_fps(self):
        self.benchmark.update(seconds=21,fps=20/21)
        with self.assertRaises(ValueError):self.check()

    def test_reject_mixed_bit(self):
        self.benchmark['bit_sha256']='OTHER'
        with self.assertRaises(ValueError):self.check()

    def test_reject_bad_repeated_head(self):
        self.benchmark['samples'][-1]['head_crc32']['out2']='bad'
        with self.assertRaises(ValueError):self.check()

    def test_reject_missing_independent_comparison(self):
        self.capture['heads']['out3']['mismatches']=None
        with self.assertRaises(ValueError):self.check()

    def test_reject_falsely_short_total_time(self):
        self.benchmark.update(seconds=2,fps=10)
        with self.assertRaises(ValueError):self.check()


if __name__=='__main__':unittest.main()
