# -*- coding: utf-8 -*-
"""Эталон логики нарезки/склейки длинной диктовки (порт в Swift сверяется
с dictation_splice_testvectors.json точь-в-точь).

Четыре детерминированные функции:
  coverage_ratio      — ловушка «частичного успеха» распознавания целого файла
  pick_cut_points     — точки реза по самым тихим окнам (не по 30.000 ровно)
  dedup_join_pair     — склейка двух кусков с дедупом перекрытия на стыке
  splice              — итог: append по порядку, отказ чанка -> маркер […]
"""
import json, re

# ------------------------------------------------------------------ покрытие
def coverage_ratio(segments, duration):
    """segments: [(start_sec, dur_sec)] из транскрипции; duration: длина файла.
    Возвращает долю файла, покрытую распознаванием (по концу последнего
    сегмента). < 0.85 => результат частичный, идти в нарезку."""
    if duration <= 0:
        return 1.0
    end = max((s + d for s, d in segments), default=0.0)
    return min(1.0, end / duration)

# ------------------------------------------------------------------ точки реза
def pick_cut_points(levels, duration, target=30.0, window=3.0, min_tail=5.0):
    """levels: [(t_sec, level_db)] таймлайн громкости (из metering волны).
    Рез не ровно по target, а в самой тихой точке окна ±window от цели.
    Следующая цель = выбранный рез + target. Хвост короче min_tail не режем."""
    cuts, goal = [], target
    while goal < duration - min_tail:
        lo, hi = goal - window, goal + window
        cand = [(lv, abs(t - goal), t) for t, lv in levels if lo <= t <= hi]
        cut = min(cand)[2] if cand else goal   # тишина, при равной — ближе к цели
        cuts.append(round(cut, 2))
        goal = cut + target
    return cuts

# ------------------------------------------------------------------ дедуп стыка
_norm = lambda w: re.sub(r"[^\wёЁ]+", "", w.lower())

def dedup_join_pair(prev, nxt, max_overlap=6):
    """Куски режутся с перекрытием ~1с — распознавание может повторить слова
    на стыке. Ищем максимальный k<=max_overlap: хвост prev == голова nxt
    (нормализованно), голову nxt отбрасываем."""
    pt, nt = prev.split(), nxt.split()
    for k in range(min(max_overlap, len(pt), len(nt)), 0, -1):
        if [_norm(w) for w in pt[-k:]] == [_norm(w) for w in nt[:k]]:
            return prev + " " + " ".join(nt[k:]) if nt[k:] else prev
    return prev + " " + nxt

# ------------------------------------------------------------------ склейка
def splice(chunk_results):
    """chunk_results: [{"ok": bool, "text": str}] в порядке чанков.
    Строго append; отказ (после повтора на стороне Swift) -> "[…]".
    Никогда не возвращаем только последний чанк."""
    out = ""
    for r in chunk_results:
        piece = r["text"].strip() if r["ok"] else "[…]"
        if not piece:
            continue
        out = dedup_join_pair(out, piece) if out else piece
    return out

# ------------------------------------------------------------------ вектора
if __name__ == "__main__":
    T1a = ("ну слушай мы выезжаем через минут сорок наверное потому что "
           "дождь зарядил сильный дорогу возле рынка опять затопило")
    T1b = ("затопило поэтому поедем через мост давай встретимся у старого "
           "кафе часов в семь или лучше в полвосьмого")
    T1c = ("и захвати пожалуйста воды бутылки три и хлеба а то у нас всё "
           "закончилось да и зарядку для телефона не забудь")

    vectors = {
        "coverage": [
            {"segments": [[0, 12.5], [13.0, 17.5]], "duration": 70.0,
             "ratio": 0.436, "partial": True},
            {"segments": [[0, 30.0], [30.5, 37.5]], "duration": 70.0,
             "ratio": 0.971, "partial": False},
            {"segments": [], "duration": 40.0, "ratio": 0.0, "partial": True},
        ],
        "cuts": [
            {"levels": [[t / 10, (-60 if t in (284, 612) else -20)]
                        for t in range(0, 700, 2)],
             "duration": 70.0, "expected": [28.4, 61.2]},
            {"levels": [[t / 10, -20] for t in range(0, 400, 2)],
             "duration": 40.0, "expected": [30.0]},
            {"levels": [], "duration": 20.0, "expected": []},
        ],
        "dedup": [
            {"prev": "пусть возьмут деньги наличными",
             "next": "деньги наличными тысячи полторы примерно",
             "joined": "пусть возьмут деньги наличными тысячи полторы примерно"},
            {"prev": "поедем через мост", "next": "Мост, встретимся у кафе",
             "joined": "поедем через мост встретимся у кафе"},
            {"prev": "буду в семь", "next": "воды три бутылки",
             "joined": "буду в семь воды три бутылки"},
        ],
        "splice": [
            {"chunks": [{"ok": True, "text": T1a},
                        {"ok": True, "text": T1b},
                        {"ok": True, "text": T1c}],
             "must_contain": ["выезжаем", "мост", "кафе", "зарядку"],
             "must_not_lose_head": "ну слушай"},
            {"chunks": [{"ok": True, "text": "первая часть про дождь"},
                        {"ok": False, "text": ""},
                        {"ok": True, "text": "третья часть про кафе"}],
             "expected": "первая часть про дождь […] третья часть про кафе"},
        ],
    }

    # самопроверка эталона + доказательство поимки «болезни перезаписи»
    for v in vectors["coverage"]:
        r = coverage_ratio([tuple(s) for s in v["segments"]], v["duration"])
        assert abs(r - v["ratio"]) < 0.005 and (r < 0.85) == v["partial"], v
    for v in vectors["cuts"]:
        assert pick_cut_points([tuple(x) for x in v["levels"]],
                               v["duration"]) == v["expected"], v
    for v in vectors["dedup"]:
        assert dedup_join_pair(v["prev"], v["next"]) == v["joined"], v
    s0 = vectors["splice"][0]
    full = splice(s0["chunks"])
    assert all(w in full for w in s0["must_contain"])
    assert full.startswith(s0["must_not_lose_head"])
    naive_last_wins = s0["chunks"][-1]["text"]          # сегодняшний баг
    assert not naive_last_wins.startswith("ну слушай") and \
           full != naive_last_wins, "эталон обязан отличаться от «последний выжил»"
    assert splice(vectors["splice"][1]["chunks"]) == \
           vectors["splice"][1]["expected"]

    json.dump(vectors, open("dictation_splice_testvectors.json", "w",
              encoding="utf-8"), ensure_ascii=False, indent=1)
    print("эталон зелёный; вектора записаны: покрытие 3, резы 3, дедуп 3, "
          "склейка 2 (включая фикстуру сегодняшнего бага)")
