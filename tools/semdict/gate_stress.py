# -*- coding: utf-8 -*-
"""Стресс гейта сущностей: ложные срабатывания и пропуски (03.08).

Единственная метрика качества, которую синтетика даёт ЧЕСТНО: здесь
важна механика (лицензирует ли русский исходник английское слово из
пивота), а не жанр речи. Цифры покрытия словаря отсюда брать нельзя —
см. шапку synthetic_stress.py и FREEZE.md.

Что считаем:
  • ложные срабатывания — гейт забраковал пивот, хотя все английские
    слова выводимы из исходника (обычно морфология: «лодочной» против
    словарного «лодка»);
  • пропуски — в пивот подсунута заведомая выдумка, а гейт её не
    заметил. Проверяется инъекцией: в пивот добавляется слово,
    которого в исходнике нет и быть не может.

Запуск: python3 tools/semdict/gate_stress.py <корпус.json> [N]
"""
import json
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "dictation_farm"))
sys.path.insert(0, HERE)

import run_farm as F                                   # noqa: E402
import farm_text as FT                                 # noqa: E402
from entity_gate import untraced_entities              # noqa: E402

# формат аргументов гейта — как в ab_entities.py (продуктовый вызов)
ENTRIES_BY_EN, ENTRIES = {}, []
for _e in FT.codec.entries.values():
    _en = (_e.get("en") or "").lower()
    if _en:
        ENTRIES_BY_EN[_en] = _e.get("ru")
        ENTRIES.append((_en, _e.get("ru")))

# Слова, которых заведомо нет ни в одном русском исходнике корпуса:
# если гейт их пропустил — это ПРОПУСК ВЫДУМКИ, худший класс ошибки.
INVENTED = ["helicopter", "lawyer", "casino", "penguin", "violin",
            "uranium", "sofa", "bishop", "tractor", "mermaid"]


def main():
    corpus = json.load(open(sys.argv[1], encoding="utf-8"))
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else len(corpus)
    corpus = corpus[:limit]
    rng = random.Random(20260803)
    started = time.time()

    stats = {"всего": 0, "семантика": 0, "гейт сущностей": 0,
             "иные отказы": 0, "ложные срабатывания": 0,
             "инъекций": 0, "пропущено выдумок": 0}
    false_positives = []
    missed = []

    for index, text in enumerate(corpus):
        stats["всего"] += 1
        reason = FT.pre_detect(text)
        result = None if reason else FT.encode_with_reason(F, text)
        outcome = (result.get("reason") if isinstance(result, dict)
                   else None) or reason
        if isinstance(result, dict) and result.get("outcome") == "semantic":
            stats["семантика"] += 1
            # инъекция выдумки в КАЖДОЕ третье прошедшее сообщение:
            # гейт обязан её поймать
            if index % 3 == 0:
                stats["инъекций"] += 1
                fake = rng.choice(INVENTED)
                spoiled = result["pivot"] + " " + fake
                caught = untraced_entities(
                    text, spoiled, ENTRIES_BY_EN, ENTRIES)
                if fake not in (caught or []):
                    stats["пропущено выдумок"] += 1
                    missed.append((text[:40], fake, f"поймано: {caught}"))
        elif outcome and "сущност" in str(outcome):
            stats["гейт сущностей"] += 1
            false_positives.append((text[:50], str(outcome)[:60]))
        elif outcome:
            stats["иные отказы"] += 1

        if stats["всего"] % 100 == 0:
            done = stats["всего"]
            speed = (time.time() - started) / done
            left = (len(corpus) - done) * speed / 60
            print(f"  {done}/{len(corpus)} — осталось ~{left:.0f} мин",
                  flush=True)

    print("\n— ИТОГ —")
    for key, value in stats.items():
        print(f"  {key}: {value}")
    if stats["семантика"]:
        share = stats["гейт сущностей"] / max(stats["всего"], 1)
        print(f"\nдоля срабатываний гейта сущностей: {share:.1%}")
    print("\nпримеры срабатываний (кандидаты в ложные):")
    for case in false_positives[:15]:
        print("  ", case)
    if missed:
        print("\nПРОПУЩЕННЫЕ ВЫДУМКИ (худший класс):")
        for case in missed[:10]:
            print("  ", case)

    out = os.path.join(os.path.dirname(sys.argv[1]), "gate_stress_report.json")
    json.dump({"stats": stats, "false_positives": false_positives,
               "missed": missed}, open(out, "w"), ensure_ascii=False, indent=1)
    print(f"\nподробности → {out}")


if __name__ == "__main__":
    main()
