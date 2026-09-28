# -*- coding: utf-8 -*-
"""Замеры Ф1 (бриф 30.07): как часто STT портит факты.

1.1 Длительность → время суток: считаем в РАСПОЗНАННЫХ текстах фермы
    паттерн «(за|через|на|в течение) Ч:ММ» — это следы превращения
    длительности в клок-форму (плюс экспозиция в эталонах: сколько раз
    длительность вообще произносится).
1.2 Съеденные предлоги: для каждой пары эталон/распознанное — биграммы
    «предлог + слово» из эталона; предлог считается съеденным, если
    слово в распознанном есть, а предлога прямо перед ним нет.

Только замер, никакой починки. Запуск:
    python3 tools/dictation_farm/stt_facts_measure.py
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))

PREPS = {"у", "к", "в", "на", "до", "от", "из", "с", "по", "за",
         "под", "над", "при", "около", "перед", "через", "без"}
DUR_CLOCK = re.compile(r"\b(за|через|на|в течение)\s+\d{1,2}:\d{2}\b",
                       re.IGNORECASE)
DUR_SPOKEN = re.compile(
    r"\b(за|через|на|в течение)\s+"
    r"(один|два|две|три|четыре|пять|шесть|семь|восемь|девять|десять|"
    r"пол|полтора|минут|час|\d+)", re.IGNORECASE)


def norm_tokens(text):
    return [t for t in re.split(r"[^а-яёa-z0-9:]+", text.lower()) if t]


def eaten_preps(ref, rec):
    """(биграмм с предлогом в эталоне, из них съедено, примеры)."""
    ref_t = norm_tokens(ref)
    rec_t = norm_tokens(rec)
    rec_set = set(rec_t)
    pairs = eaten = 0
    examples = []
    for i, tok in enumerate(ref_t[:-1]):
        if tok in PREPS and ref_t[i + 1] not in PREPS \
           and len(ref_t[i + 1]) >= 3:
            pairs += 1
            noun = ref_t[i + 1]
            if noun in rec_set:
                # предлог на месте, если где-то в распознанном есть
                # биграмма «этот предлог + это слово»
                ok = any(rec_t[j] == tok and rec_t[j + 1] == noun
                         for j in range(len(rec_t) - 1))
                if not ok:
                    eaten += 1
                    examples.append(f"{tok} {noun}")
    return pairs, eaten, examples


def main():
    manifest = {m["file"]: m["text"] for m in
                json.load(open(os.path.join(HERE, "out/manifest.json")))}
    recognized = json.load(open(os.path.join(HERE, "farm_recognized.json")))

    clock_hits = []
    spoken_total = 0
    pairs_total = eaten_total = 0
    eaten_examples = []
    files = 0

    for r in recognized["results"]:
        rec = r.get("text") or ""
        ref = manifest.get(r["file"].removeprefix("farm_"))
        if ref is None:
            continue
        files += 1
        for m in DUR_CLOCK.finditer(rec):
            clock_hits.append((r["file"], m.group(0)))
        spoken_total += len(DUR_SPOKEN.findall(ref))
        p, e, ex = eaten_preps(ref, rec)
        pairs_total += p
        eaten_total += e
        eaten_examples += [(r["file"], x) for x in ex]

    print(f"файлов с эталонами: {files}")
    print(f"\n— 1.1 длительность → клок-форма —")
    print(f"экспозиция (длительностей произнесено в эталонах): {spoken_total}")
    print(f"клок-форм после предлогов длительности в распознанном: "
          f"{len(clock_hits)}")
    for f, s in clock_hits[:12]:
        print(f"  {f}: «{s}»")

    print(f"\n— 1.2 предлоги —")
    print(f"биграмм «предлог+слово» в эталонах: {pairs_total}")
    share = eaten_total / pairs_total * 100 if pairs_total else 0
    print(f"съедено (слово есть, предлога перед ним нет): "
          f"{eaten_total} ({share:.1f}%)")
    for f, x in eaten_examples[:15]:
        print(f"  {f}: «{x}»")


if __name__ == "__main__":
    main()
