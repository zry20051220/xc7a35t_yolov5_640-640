import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from prepare_scut_head import convert_box,duplicate_exclusions


class HeadBoxTest(unittest.TestCase):
    def test_normalized_box(self):
        box,clipped=convert_box((10,20,30,50),100,100)
        self.assertEqual(box,(.2,.35,.2,.3))
        self.assertFalse(clipped)

    def test_clip_image_boundary(self):
        box,clipped=convert_box((-5,0,105,100),100,100)
        self.assertEqual(box,(.5,.5,1,1))
        self.assertTrue(clipped)

    def test_reject_zero_area(self):
        with self.assertRaises(ValueError):convert_box((10,10,10,30),100,100)

    def test_reject_completely_outside(self):
        with self.assertRaises(ValueError):convert_box((110,10,120,30),100,100)

    def test_reject_nonfinite(self):
        with self.assertRaises(ValueError):convert_box((0,0,float('nan'),30),100,100)

    def test_dedup_keeps_test_and_preserves_same_split_duplicates(self):
        groups={'a':[('train_a','train'),('val_a','val'),('test_a','test')],
                'b':[('train_b','train'),('val_b','val')],
                'c':[('test_c1','test'),('test_c2','test')]}
        removed=duplicate_exclusions(groups)
        self.assertEqual({entry['id'] for entry in removed},{'train_a','val_a','train_b'})
        self.assertFalse(any(entry['split']=='test' for entry in removed))


if __name__=='__main__':unittest.main()
