# -*- coding: utf-8 -*-
"""
scoring.py — cost-weighted оценка гейта извлечения (шаг 4 линии Софи).

Асимметрия из waku-agent: ПРОПУЩЕННЫЙ факт (FN) вчетверо дороже лишнего
поиска (FP) — пользователь замечает «Софи забыла», но не замечает лишний
дешёвый поиск. Планка 0.5 — как у waku (жёсткая при такой цене FN).
"""

COST_FN = 4      # пропустили нужную память
COST_FP = 1      # искали зря
THRESHOLD = 0.5  # планка гейта


def cost_weighted_score(tp, fp, tn, fn):
    """1 − (FN·4 + FP·1) / худший_случай; пустой корпус = 1.0."""
    positives = tp + fn
    negatives = tn + fp
    worst = positives * COST_FN + negatives * COST_FP
    if worst == 0:
        return 1.0
    return 1.0 - (fn * COST_FN + fp * COST_FP) / worst
