import unittest
import numpy as np
from decode_detections import decode_heads, nms


class DecodeTest(unittest.TestCase):
    def setUp(self):
        self.heads = [np.zeros((75, size, size), dtype=np.uint8) for size in (20, 40, 80)]
        self.params = [dict(output_scale=1, output_zero_point=128)] * 3
        self.anchors = np.array(((10, 13), (16, 30), (33, 23), (30, 61), (62, 45),
                                 (59, 119), (116, 90), (156, 198), (373, 326)))

    def test_empty_frame(self):
        result = decode_heads(self.heads, self.params, self.anchors, (480, 800))
        self.assertEqual(result.shape, (0, 6))

    def test_320_letterbox_inverse(self):
        heads = [np.zeros((75, size, size), dtype=np.uint8) for size in (10, 20, 40)]
        heads[2][:4, 20, 10] = 128
        heads[2][4, 20, 10] = 255
        heads[2][5+14, 20, 10] = 255
        geometry = dict(size=320, left=0, top=100, scale_x=.5, scale_y=.5)
        result = decode_heads(heads, self.params, self.anchors, (240, 640),
                              input_size=320, letterbox=geometry)
        np.testing.assert_allclose(result[0, :4], (158, 115, 178, 141))

    def test_anchor_and_direct_resize(self):
        # Anchor 0 of the stride-8 head: center=(12,20), wh=(10,13).
        head = self.heads[2]
        head[:4, 2, 1] = 128
        head[4, 2, 1] = 255
        head[5+14, 2, 1] = 255
        result = decode_heads(self.heads, self.params, self.anchors, (320, 1280))
        self.assertEqual(result.shape, (1, 6))
        np.testing.assert_allclose(result[0, :4], (14, 6.75, 34, 13.25))
        self.assertEqual(result[0, 5], 14)
        self.assertGreater(result[0, 4], .99)

    def test_nms_keeps_nonoverlap(self):
        boxes = np.array(((0, 0, 10, 10), (0, 0, 10, 10), (20, 20, 30, 30)))
        self.assertEqual(nms(boxes, np.array((.9, .8, .7)), .3).tolist(), [0, 2])

    def test_wrong_input_dtype(self):
        self.heads[0] = self.heads[0].astype(np.int8)
        with self.assertRaises(ValueError):
            decode_heads(self.heads, self.params, self.anchors, (640, 640))


if __name__ == '__main__':
    unittest.main()
