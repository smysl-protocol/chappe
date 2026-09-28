# -*- coding: utf-8 -*-
"""Ф1.3: A/B contextualStrings — «до» (28.07, без подсказок) против
«после» (перегон с подсказками: ru-слова словаря; контакты и газетир
на симуляторе пусты). Метрики на эталонах manifest.json:

  - дыры: доля содержательных слов эталона (≥4 букв), которых нет
    в распознанном (по формам, без стемминга — консервативно);
  - съеденные предлоги: биграммы «предлог+слово» без предлога;
  - клок-формы после предлогов длительности (след порчи 1.1).

Запуск: python3 context_ab_compare.py <after.json> [before.json]
(без второго аргумента «до» = farm_recognized.json 28.07, симулятор)
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from stt_facts_measure import norm_tokens, eaten_preps, DUR_CLOCK  # noqa: E402


def holes(ref, rec):
    ref_words = [t for t in norm_tokens(ref) if len(t) >= 4]
    rec_set = set(norm_tokens(rec))
    missing = [w for w in ref_words if w not in rec_set]
    return len(ref_words), len(missing)


def collect(path, manifest):
    data = json.load(open(path))
    stats = {"files": 0, "ref_words": 0, "holes": 0,
             "prep_pairs": 0, "prep_eaten": 0, "clock": 0}
    for r in data["results"]:
        ref = manifest.get(r["file"].removeprefix("farm_"))
        rec = r.get("text") or ""
        if ref is None:
            continue
        stats["files"] += 1
        t, m = holes(ref, rec)
        stats["ref_words"] += t
        stats["holes"] += m
        p, e, _ = eaten_preps(ref, rec)
        stats["prep_pairs"] += p
        stats["prep_eaten"] += e
        stats["clock"] += len(DUR_CLOCK.findall(rec))
    return stats


def line(tag, s):
    hole_pct = s["holes"] / s["ref_words"] * 100 if s["ref_words"] else 0
    prep_pct = s["prep_eaten"] / s["prep_pairs"] * 100 if s["prep_pairs"] else 0
    print(f"{tag}: файлов {s['files']}, дыры {s['holes']}/{s['ref_words']} "
          f"({hole_pct:.1f}%), предлоги съедены {s['prep_eaten']}/"
          f"{s['prep_pairs']} ({prep_pct:.1f}%), клок-форм {s['clock']}")


def main():
    manifest = {m["file"]: m["text"] for m in
                json.load(open(os.path.join(HERE, "out/manifest.json")))}
    before_path = sys.argv[2] if len(sys.argv) > 2 \
        else os.path.join(HERE, "farm_recognized.json")
    before = collect(before_path, manifest)
    after = collect(sys.argv[1], manifest)
    line("ДО  (без подсказок)", before)
    line("ПОСЛЕ (со словами словаря)", after)


if __name__ == "__main__":
    main()
