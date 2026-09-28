# -*- coding: utf-8 -*-
"""Проверка источников пака знаний (бриф 02.08, п.2).

Правила (--strict включает все):
 1. каждый ID источника, упомянутый в паке/манифесте, существует в
    packs/kb_sources.json;
 2. у каждого источника реестра есть level и verified_at; url обязателен,
    кроме явного null (S11 — вторичные базы);
 3. в тексте секций пака НЕТ URL (http/https/www) — ссылки живут только
    в реестре;
 4. каждый источник манифеста используется хотя бы одной секцией.

Запуск: python3 tools/kb/check_sources.py --strict packs/history_chappe_v0.md
Выход 0 — чисто; 1 — нарушения (перечисляются).
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REGISTRY = os.path.join(HERE, "..", "..", "packs", "kb_sources.json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pack")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    registry = {s["id"]: s for s in
                json.load(open(REGISTRY, encoding="utf-8"))["sources"]}
    pack = open(args.pack, encoding="utf-8").read()
    problems = []

    # 1. все ID из пака существуют (семейство ID — <ПРЕФИКС>-S<номер>)
    used = set(re.findall(r"[A-Z]+-S\d+", pack))
    for sid in sorted(used):
        if sid not in registry:
            problems.append(f"ID {sid} в паке отсутствует в реестре")

    # 2. полнота реестра
    for sid, s in registry.items():
        if not s.get("level"):
            problems.append(f"{sid}: нет level")
        if not s.get("verified_at"):
            problems.append(f"{sid}: нет verified_at")
        if "url" not in s:
            problems.append(f"{sid}: нет поля url (null допустим, отсутствие — нет)")

    # 3. URL в тексте секций запрещены
    for m in re.finditer(r"https?://\S+|www\.\S+", pack):
        problems.append(f"URL в тексте пака: {m.group(0)[:60]}")

    # 4. strict: каждый заявленный источник где-то используется.
    # Реестр общий на все паки, поэтому проверяем только семейства
    # (префиксы ID), которыми пользуется ЭТОТ пак: чужие семейства —
    # забота своих паков.
    if args.strict:
        prefixes = {sid.split("-S")[0] for sid in used}
        for sid in registry:
            if sid.split("-S")[0] in prefixes and sid not in used:
                problems.append(f"{sid} есть в реестре, но не упомянут паком "
                                f"(strict)")

    print(f"пак: {os.path.basename(args.pack)}; источников использовано: "
          f"{len(used)}/{len(registry)}")
    for p in problems:
        print("ПРОБЛЕМА:", p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
