import unittest
import zlib
from tensor_protocol import HEADER, TensorAssembler


def packet(offset, body, frame=252):
    return HEADER.pack(b'DAT1', frame, offset, zlib.crc32(body))+body


class TensorProtocolTest(unittest.TestCase):
    def test_out_of_order_and_duplicate(self):
        assembler = TensorAssembler(252, 600)
        self.assertFalse(assembler.accept(packet(512, b'b'*88)))
        self.assertFalse(assembler.accept(packet(512, b'b'*88)))
        self.assertEqual(assembler.missing_offsets(), [0])
        self.assertTrue(assembler.accept(packet(0, b'a'*512)))
        self.assertEqual(assembler.data, b'a'*512+b'b'*88)

    def test_corruption(self):
        assembler = TensorAssembler(252, 512)
        damaged = bytearray(packet(0, b'a'*512))
        damaged[-1] ^= 1
        with self.assertRaises(ValueError):
            assembler.accept(damaged)
        self.assertFalse(assembler.complete)

    def test_wrong_frame_and_length(self):
        assembler = TensorAssembler(252, 600)
        for value in (packet(0, b'a'*512, 253), packet(512, b'b'*87), packet(1, b'a'*512)):
            with self.assertRaises(ValueError):
                assembler.accept(value)


if __name__ == '__main__':
    unittest.main()
