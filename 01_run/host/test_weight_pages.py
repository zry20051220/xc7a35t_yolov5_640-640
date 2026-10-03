import unittest
from upload_weight_pages import weight_pages, FRAME_BYTES
from eth_protocol import HEADER, build_weight_packet, validate_packet


class WeightPageTest(unittest.TestCase):
    def test_padding_and_page_id(self):
        data = b'a'*FRAME_BYTES+b'last'
        pages = list(weight_pages(data, 247))
        self.assertEqual([p[1] for p in pages], [247, (1 << 24)|247])
        self.assertEqual(pages[0][2], b'a'*FRAME_BYTES)
        self.assertEqual(pages[1][2], b'last'+bytes(FRAME_BYTES-4))
        packet = build_weight_packet(pages[1][1], 0, 878, pages[1][2][:1400])
        self.assertTrue(validate_packet(packet))
        self.assertEqual(HEADER.unpack(packet[:HEADER.size])[3] >> 24, 1)

    def test_reject_feature_overlap(self):
        with self.assertRaises(ValueError):
            list(weight_pages(bytes(3*FRAME_BYTES+1), 247))

    def test_reject_reserved_frame_bits(self):
        with self.assertRaises(ValueError):
            list(weight_pages(b'x', 1 << 24))


if __name__ == '__main__':
    unittest.main()
