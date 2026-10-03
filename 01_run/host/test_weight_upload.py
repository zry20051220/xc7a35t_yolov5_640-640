import binascii
import unittest

from eth_protocol import HEADER, TYPE_WEIGHTS, build_weight_packet, validate_packet
from send_first_layer_weights import FRAME_BYTES, ROOT, payload_bytes


class WeightUploadTest(unittest.TestCase):
    def test_first_layer_payload_and_padding(self):
        payload, useful = payload_bytes()
        blob = (ROOT / "weights/yolov5n_int8_weights.bin").read_bytes()
        self.assertEqual(useful, 1856)
        self.assertEqual(len(payload), FRAME_BYTES)
        self.assertEqual(payload[:useful], blob[:useful])
        self.assertEqual(payload[useful:], bytes(FRAME_BYTES - useful))
        self.assertEqual(binascii.crc32(payload), 0xBB035D95)

    def test_weight_packet_type_and_crc(self):
        packet = build_weight_packet(200, 0, 1, b"abc", True)
        self.assertTrue(validate_packet(packet))
        self.assertEqual(HEADER.unpack(packet[:HEADER.size])[2], TYPE_WEIGHTS)


if __name__ == "__main__":
    unittest.main()
