# -*- coding: utf-8 -*-
"""A/B промпта пивота v1 → v2 (правило 9: запрет новых сущностей) по
ENTITIES + метрика «пивот добавил сущность» (п.5 брифа 31.07).

Корпус: tatoeba_ru (100 входов, как в farm_text). live_2026-07-29 не
найден — блокер записан в отчёте. Нужен llama-server на :8080.

Запуск: python3 tools/dictation_farm/ab_entities.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))

import run_farm as F                                    # noqa: E402
import farm_text as FT                                  # noqa: E402
from entity_gate import untraced_entities               # noqa: E402

ENTRIES_BY_EN = {}
ENTRIES = []
for e in F.codec.entries.values():
    en = (e.get("en") or "").lower()
    if en:
        ENTRIES_BY_EN[en] = e.get("ru")
        ENTRIES.append((en, e.get("ru")))


def run_variant(tag, prompt_file, texts):
    F.PROMPT = open(os.path.join(HERE, "..", "semdict", prompt_file),
                    encoding="utf-8").read().strip()
    stats = dict(n=0, semantic=0, added_inputs=0, added_words=[],
                 ent_ok=0, ent_all=0)
    for text in texts:
        stats["n"] += 1
        if FT.pre_detect(text) is not None:
            continue
        r = FT.encode_with_reason(F, text)
        if not isinstance(r, dict) or r.get("outcome") != "semantic":
            continue
        stats["semantic"] += 1
        untraced_entities(text, r["pivot"], ENTRIES_BY_EN, ENTRIES)
        # две корзины по классификации САМОГО гейта: настоящие выдуманные
        # сущности (словарные существительные и NAME:) против
        # внесловарной лексики (перевод вне лексикона — слабость словаря)
        kinds = untraced_entities.last_kinds
        invented = [w for w, k in kinds if k in ("name", "noun")]
        offlex = [w for w, k in kinds if k == "offlex"]
        if invented:
            stats["added_inputs"] += 1
            stats["added_words"].append((text[:50], invented))
        if offlex:
            stats["offlex_inputs"] = stats.get("offlex_inputs", 0) + 1
        if invented or offlex:
            stats["gated_to_text"] = stats.get("gated_to_text", 0) + 1
        for cat, fact, ok in FT.facts_score(text, r["rendered"]):
            if cat == "entities":
                stats["ent_all"] += 1
                stats["ent_ok"] += ok
    share = stats["added_inputs"] / stats["semantic"] * 100 \
        if stats["semantic"] else 0
    ent = stats["ent_ok"] / stats["ent_all"] * 100 if stats["ent_all"] else 0
    gated = stats.get("gated_to_text", 0)
    sem_after = stats["semantic"] - gated
    print(f"{tag}: входов {stats['n']}, семантикой ДО гейта "
          f"{stats['semantic']} ({stats['semantic']}%), ПОСЛЕ гейта "
          f"{sem_after} ({sem_after}%) [пост-хок, без перегенераций — "
          f"нижняя граница]; (а) ВЫДУМАНЫ сущности: {stats['added_inputs']} "
          f"входов; (б-остаток) внесловарная лексика: "
          f"{stats.get('offlex_inputs', 0)} входов; "
          f"ENTITIES {stats['ent_ok']}/{stats['ent_all']} ({ent:.1f}%)")
    for src, bad in stats["added_words"][:8]:
        print(f"   «{src}…» → {bad}")
    return stats


def main():
    texts = FT.load_tatoeba(100)
    run_variant("v1 (текущий)  ", "pivot_prompt_chat_v1.txt", texts)
    run_variant("v2 (правило 9)", "pivot_prompt_chat_v2.txt", texts)


if __name__ == "__main__":
    main()
