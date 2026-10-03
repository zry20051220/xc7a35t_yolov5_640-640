import sys
import unittest
from pathlib import Path

import torch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from train_head_qat import qat_config


class QatContractTests(unittest.TestCase):
    def test_weight_zero_point_is_symmetric(self):
        quantizer=qat_config().weight()
        quantizer(torch.tensor([-1.0,-.1,.2,.8]))
        self.assertEqual(quantizer.dtype,torch.qint8)
        self.assertEqual(quantizer.qscheme,torch.per_tensor_symmetric)
        self.assertEqual(quantizer.zero_point.item(),0)
        self.assertEqual(quantizer.scale.numel(),1)

    def test_activation_is_uint8(self):
        quantizer=qat_config().activation()
        quantizer(torch.tensor([-.2,0.,1.]))
        self.assertEqual(quantizer.dtype,torch.quint8)
        self.assertEqual((quantizer.quant_min,quantizer.quant_max),(0,255))

    def test_disabled_observer_does_not_learn_from_validation(self):
        quantizer=qat_config().activation()
        quantizer(torch.tensor([0.,1.]))
        scale=quantizer.scale.clone()
        quantizer.disable_observer()
        quantizer(torch.tensor([0.,1000.]))
        torch.testing.assert_close(quantizer.scale,scale)


if __name__=='__main__':unittest.main()
