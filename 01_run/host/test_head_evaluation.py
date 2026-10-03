import sys
import unittest
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from evaluate_head import match,decode


class HeadMatchingTests(unittest.TestCase):
    def test_decode_320_and_640_use_actual_geometry(self):
        for size in [320,640]:
            with self.subTest(size=size):
                outputs=[torch.full((1,18,size//stride,size//stride),-100.) for stride in [32,16,8]]
                outputs[2][0,:6,7,5]=0
                geometry=dict(size=size,left=0,top=0,scale_x=1,scale_y=1)
                rows=decode(outputs,np.asarray([[10,13]]*9,dtype=np.float32),geometry,(size,size,3),confidence=.2)
                self.assertEqual(rows.shape,(1,5))
                np.testing.assert_allclose((rows[0,:2]+rows[0,2:4])/2,[44,60])
                np.testing.assert_allclose(rows[0,2:4]-rows[0,:2],[10,13])

    def test_duplicate_detection_not_counted_twice(self):
        pred=np.array([[0,0,10,10,.9],[0,0,10,10,.8]])
        truth=np.array([[0,0,10,10]])
        np.testing.assert_array_equal(match(pred,truth),[True,False])

    def test_empty_truth(self):
        np.testing.assert_array_equal(match(np.array([[0,0,10,10,.9]]),np.empty((0,4))),[False])

    def test_empty_predictions(self):
        self.assertEqual(match(np.empty((0,5)),np.array([[0,0,10,10]])).dtype,np.dtype(bool))

    def test_distinct_heads(self):
        pred=np.array([[0,0,10,10,.9],[20,20,30,30,.8]])
        np.testing.assert_array_equal(match(pred,pred[:,:4]),[True,True])


if __name__=='__main__': unittest.main()
