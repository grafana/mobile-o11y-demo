import unittest
import numpy as np
from fair_analyze import quality, visible


class QualityMetricTest(unittest.TestCase):
    def reference(self):
        # High-contrast generated glyph-like stripes, not a flat gray image.
        image = np.full((64, 64, 3), 245, dtype=np.float32)
        image[20:45, 10:55:4] = 20
        return image

    def test_identical_pixels_score_as_lossless(self):
        image = self.reference()
        report = quality(image, image.copy(), np.ones((64, 64), bool))
        self.assertEqual(99, report['visiblePsnrDb'])
        self.assertAlmostEqual(1, report['visibleBlockSsim'])

    def test_masked_changes_do_not_inflate_or_degrade_visible_quality(self):
        image = self.reference()
        candidate = image.copy()
        candidate[:16] = 0
        mask = np.ones((64, 64), bool)
        mask[:16] = False
        report = quality(image, candidate, mask)
        self.assertEqual(99, report['visiblePsnrDb'])
        self.assertAlmostEqual(1, report['visibleBlockSsim'])

    def test_erasing_visible_text_fails_quality_even_with_most_pixels_unchanged(self):
        image = self.reference()
        candidate = np.full_like(image, 245)
        report = quality(image, candidate, np.ones((64, 64), bool))
        self.assertLess(report['visiblePsnrDb'], 20)
        self.assertLess(report['visibleBlockSsim'], .8)
        self.assertLess(report['textEdgePsnrDb'], 20)

    def test_visible_mask_scales_from_original_and_excludes_filter_edges(self):
        frame = dict(width=40, height=80, originalWidth=80, originalHeight=160,
                     originalMasks=[[10, 20, 30, 60]])
        mask = visible(frame)
        self.assertFalse(mask[8:32, 3:17].any())
        self.assertTrue(mask[0, 0])


if __name__ == '__main__':
    unittest.main()
