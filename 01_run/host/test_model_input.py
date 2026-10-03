import unittest

import numpy as np

from model_input import quantized_focus_bgr, letterbox_bgr


class ModelInputTest(unittest.TestCase):
    def test_320_letterbox_geometry(self):
        image = np.full((240, 640, 3), 50, dtype=np.uint8)
        padded, geometry = letterbox_bgr(image)
        self.assertEqual(geometry, dict(size=320, left=0, top=100, scale_x=.5, scale_y=.5))
        np.testing.assert_array_equal(padded[0, 0], (114, 114, 114))
        np.testing.assert_array_equal(padded[100, 0], (50, 50, 50))
        self.assertEqual(quantized_focus_bgr(image, 1 / 255, 320, True).shape, (12, 160, 160))

    def test_invalid_model_size(self):
        with self.assertRaises(ValueError):
            quantized_focus_bgr(np.zeros((10, 10, 3), dtype=np.uint8), 1, 319)

    def test_focus_channel_and_pixel_order(self):
        bgr = np.zeros((640, 640, 3), dtype=np.uint8)
        for y in range(640):
            for x in range(640):
                bgr[y, x] = (x % 256, y % 256, (x + y) % 256)
        focus = quantized_focus_bgr(bgr, 1.0 / 255.0)
        self.assertEqual(focus.shape, (12, 320, 320))
        self.assertEqual(focus.dtype, np.uint8)
        for fy, fx in ((0, 0), (13, 27), (319, 319)):
            for group, (dy, dx) in enumerate(((0, 0), (1, 0), (0, 1), (1, 1))):
                pixel = bgr[2 * fy + dy, 2 * fx + dx]
                np.testing.assert_array_equal(focus[group * 3:group * 3 + 3, fy, fx],
                                              pixel[::-1])


if __name__ == '__main__':
    unittest.main()
