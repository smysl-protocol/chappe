# -*- coding: utf-8 -*-
"""Замки английских междометий в гейте пропажи (бриф 06.08 п.4).

Случаи NUS-замера 05.08 (отчёт english_corpus_2026-08-05.md §4 п.2,
записаны ДО починки): «потеряно слово haha/hiya/hmmm/alright/dont» —
ложные срабатывания; настоящая потеря («we leaving 4 sharp» → пивот
без sharp) обязана ловиться по-прежнему.

Зеркало Swift — MissingGateEnglishTests.
Запуск: python3 tools/dictation_farm/test_missing_gate_en.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))

import rescue_measure as RM  # noqa: E402


def check(cond, label):
    if not cond:
        print(f"ЗАМОК СЛОМАН: {label}")
    return bool(cond)


def main():
    ok = True

    # междометия и безапострофные формы — не «потерянные слова»
    cases = [
        ("Wah haha alright. You watched it?",
         [("lit", "you watched it ?")], "you watched it ?"),
        ("Hmmm... Green? So wat does it mean....",
         [("lit", "green ? so what does it mean")],
         "green ? so what does it mean"),
        ("TIME IS VERY VALUEBLE,DONT WASTE IT",
         [("lit", "time is very valuable waste it")],
         "time is very valuable waste it"),
        ("hahaha okay gonna sleep now goodnight",
         [("lit", "okay sleep now goodnight")],
         "okay sleep now goodnight"),
    ]
    for src, units, rendered in cases:
        got = RM.missing_noun_gate(src, units, rendered)
        ok &= check(got is None, f"ложная пропажа на «{src[:40]}»: {got}")

    # настоящая потеря ловится по-прежнему (класс #5 NUS: sharp)
    got = RM.missing_noun_gate("Lol we leaving 4 sharp",
                               [("lit", "we leave at 4 .")],
                               "we leave at 4 .")
    ok &= check(got is not None and "sharp" in got,
                f"настоящая потеря sharp не поймана: {got}")
    # и русская пропажа не разлочена (фикстура красной сессии)
    got = RM.missing_noun_gate("собери рюкзак и спальник к вечеру",
                               [("lit", "собери рюкзак к вечеру")],
                               "собери рюкзак к вечеру")
    ok &= check(got is not None and "спальник" in got,
                f"русская пропажа спальник не поймана: {got}")

    print("замки целы" if ok else "есть сломанные замки")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
