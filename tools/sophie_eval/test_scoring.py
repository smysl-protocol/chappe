# -*- coding: utf-8 -*-
"""
test_scoring.py — замок формулы cost-weighted (правило №4: ожидания
посчитаны РУКАМИ, не выведены из кода).

Запуск: python3 tools/sophie_eval/test_scoring.py
"""

import unittest

from scoring import cost_weighted_score


class TestCostWeighted(unittest.TestCase):

    def test_hand_computed_mixed(self):
        # Руками: P = 2+1 = 3, N = 3+1 = 4; худший = 3·4 + 4·1 = 16;
        # потери = 1·4 + 1·1 = 5; счёт = 1 − 5/16 = 0.6875
        self.assertAlmostEqual(
            cost_weighted_score(tp=2, fp=1, tn=3, fn=1), 0.6875)

    def test_perfect_is_one(self):
        self.assertEqual(cost_weighted_score(tp=5, fp=0, tn=5, fn=0), 1.0)

    def test_all_misses_is_zero(self):
        # Руками: худший = 3·4 = 12, потери = 3·4 = 12 → 0.0
        self.assertEqual(cost_weighted_score(tp=0, fp=0, tn=0, fn=3), 0.0)

    def test_fn_hurts_four_times_more_than_fp(self):
        # Руками: 1 FN на корпусе 1P+9N: худший = 4+9 = 13 → 1−4/13 ≈ 0.6923
        #         1 FP на том же:                потери = 1 → 1−1/13 ≈ 0.9231
        with_fn = cost_weighted_score(tp=0, fp=0, tn=9, fn=1)
        with_fp = cost_weighted_score(tp=1, fp=1, tn=8, fn=0)
        self.assertAlmostEqual(with_fn, 1 - 4 / 13)
        self.assertAlmostEqual(with_fp, 1 - 1 / 13)
        self.assertLess(with_fn, with_fp)


if __name__ == "__main__":
    unittest.main()
