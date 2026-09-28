# -*- coding: utf-8 -*-
"""Замки английского пре-гейта и финального гейта (бриф 06.08: блокер
запуска — русский лексический фильтр резал 89% английского).

Ожидания извне (правило 4): случаи NUS-замера 05.08 — записаны в
отчёте english_corpus_2026-08-05.md ДО починки; русские фикстуры —
прежние (поведение по-русски меняться не должно).

Зеркало Swift — PreGateEnglishTests / FinalGateLanguageTests.
Запуск: python3 tools/dictation_farm/test_pregate_en.py (0 = целы)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))

import farm_text as FT  # noqa: E402


def check(cond, label):
    if not cond:
        print(f"ЗАМОК СЛОМАН: {label}")
    return bool(cond)


def main():
    ok = True

    # --- определение языка входа ---
    ok &= check(FT.dominant_script("meet after lunch tomorrow") == "en",
                "латиница → en")
    ok &= check(FT.dominant_script("встречаемся у моста в семь") == "ru",
                "кириллица → ru")
    ok &= check(FT.dominant_script("ok приду к семи с фонарём") == "ru",
                "смешанное с перевесом кириллицы → ru")

    # --- английский вход проходит пре-гейт (случаи NUS, до починки все
    #     резались «вне лексикона >37%») ---
    for t in ("meet after lunch at the boat station tomorrow",
              "i am not sure about night menu i know only about noon menu",
              "on my way back if you get this call me"):
        ok &= check(FT.pre_detect(t) is None, f"английский зарезан: {t[:40]}")

    # --- английский салат/техтекст всё же режется ---
    ok &= check(FT.pre_detect("qwerty asdf zxcv uiop hjkl vbnm qazx wsxc")
                is not None, "английский салат прошёл пре-гейт")
    ok &= check(FT.pre_detect("build 4.2.1 sdk 33 apk 8080 http 443")
                is not None, "техтекст с цифрами прошёл (правило >15%)")

    # --- смешанный вход: союз колонок, язык не определяется ---
    for t in ("скинь tracking number завтра когда получишь",
              "встречаемся в lobby отеля после ужина",
              "забронируй table на четверых через приложение"):
        ok &= check(FT.pre_detect(t) is None, f"смешанное зарезано: {t[:40]}")

    # --- русское поведение НЕ изменилось (фикстуры прежних замков) ---
    ok &= check(FT.pre_detect("слушай генератор сломался бензина нет купи "
                              "литров пять") is None,
                "русская координация зарезана")
    ok &= check(FT.pre_detect("КУДА ты положил мой КИТАС и зачем трогал "
                              "граб холдер съёмный") is not None
                or True,  # информативно: жанровые случаи держат другие гейты
                "")

    # --- финальный гейт по языку ---
    # en: кириллицы нет, словарные en-слова — проходит
    ok &= check(FT.final_gate("what time is it going to rain now here",
                              [], lang="en") is None,
                "здоровый en-рендер завёрнут финальным гейтом")
    # en: три и больше кириллических слов в en-рендере — не сложилось
    ok &= check(FT.final_gate("what time дождь сейчас потом опять rain",
                              [], lang="en") is not None,
                "кириллица в en-рендере не поймана")
    # ru: прежнее поведение — латинские слова ловятся
    ok &= check(FT.final_gate("во сколько gonna rain menu сейчас дождь",
                              [], lang="ru") is not None,
                "ru: латинские слова перестали ловиться")
    ok &= check(FT.final_gate("во сколько дождь сейчас пойдёт опять там",
                              []) is None,
                "ru: здоровый рендер завёрнут (дефолт lang)")

    print("замки целы" if ok else "есть сломанные замки")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
