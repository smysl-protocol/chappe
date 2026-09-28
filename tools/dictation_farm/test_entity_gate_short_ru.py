# -*- coding: utf-8 -*-
"""Замки лечения короткой ru-колонки гейта сущностей (решение 05.08).

Основание — live_corpus_2026-08-05.md §5: 631 флаг из 3 629 (17%) —
слова, у которых ВСЕ ru-слова короче 4 букв («как», «где», «раз»):
префиксная трассировка (стем ≥4) не может проследить их в принципе,
70 сообщений из 1 698 переворачивались целиком. Лечение: короткое
ru-слово сверяется с входом ЦЕЛИКОМ (е/ё нормализованы), длинные —
прежним префиксом; порог стема не тронут.

Ожидания — ИЗВНЕ (правило 4): примеры вылеченных — дословно из
промера §5 отчёта, до реализации лечения; ожидание «выдуманное
короткое ловится по-прежнему» — из смысла гейта (бриф 31.07).

Зеркало Swift — ChappeTests/EntityGateTests («короткая ru-колонка»),
расхождение зеркал = баг.
Запуск: python3 tools/dictation_farm/test_entity_gate_short_ru.py
(0 = замки целы)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))

import farm_text as FT  # noqa: E402
from entity_gate import untraced_entities  # noqa: E402

codec = FT.codec
ENTS = {e["en"].lower(): e.get("ru") for e in codec.entries.values()}
PAIRS = [(e["en"], e.get("ru")) for e in codec.entries.values()]


def gate(source, pivot):
    return untraced_entities(source, pivot, ENTS, PAIRS)


def check(cond, label):
    if not cond:
        print(f"ЗАМОК СЛОМАН: {label}")
    return bool(cond)


def main():
    ok = True

    # Вылеченные примеры промера §5 — слово входа есть, флага быть
    # не должно (до лечения все три горели: where/how/times)
    ok &= check(gate("А где здесь можно купить матэ?",
                     "where to buy NAME:Mate here") == [],
                "«где» во входе — where не флаг")
    ok &= check(gate("Это как? Просто интересно стало почему так",
                     "how is this and why") == [],
                "«как» во входе — how не флаг")
    ok &= check("times" not in gate("раз пять на байке ездил туда",
                                    "rode there 5 times"),
                "«раз» во входе — times не флаг")

    # Защита от перелечивания: короткое ru-слово, которого во входе
    # НЕТ, флагуется по-прежнему (food → «еда»)
    ok &= check("food" in gate("задержусь приболел по ходу немного",
                               "i am late and sick bring food"),
                "food без «еда» во входе — флаг остаётся")

    # Точная сверка, не подстрока: «карта» содержит «как» подстрокой,
    # но целым словом «как» во входе нет — how остаётся флагом
    ok &= check("how" in gate("карта дорог у меня с собой лежит",
                              "how is the road map"),
                "подстрока не считается: «карта» не лицензирует how")

    # е/ё: нормализация обязана работать на короткой сверке
    ru_yo = [(en, ru) for en, ru in PAIRS
             if ru and len(ru) <= 3 and "ё" in ru]
    if ru_yo:
        en, ru = ru_yo[0]
        src = f"тут {ru.replace('ё', 'е')} привезли вчера вечером"
        ok &= check(en.lower() not in [t.lower() for t in gate(src, en)],
                    f"е/ё: «{ru}» найдено как «{ru.replace('ё', 'е')}»")

    # Длинные ru-слова: поведение не тронуто (стем ≥4 прежний) —
    # честный пивот проходит, обобщение ловится (фикстуры брифа 31.07)
    ok &= check(gate("задержусь так как неважно себя чувствую приболел",
                     "i will be late i feel sick") == [],
                "длинные: честный пивот проходит как раньше")
    ok &= check(gate("задержусь приболел по ходу немного",
                     "i have problems with health") != [],
                "длинные: обобщение ловится как раньше")

    print("замки целы" if ok else "есть сломанные замки")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
