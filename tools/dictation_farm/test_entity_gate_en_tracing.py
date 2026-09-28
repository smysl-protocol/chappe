# -*- coding: utf-8 -*-
"""Замки английской трассировки гейта сущностей (очередь владельца
06.08: «сокращения в трассировке»). Случаи — дословно из NUS-замера
(флаги записаны в отчётах ДО починки), классы промера на чекпойнте:
because ×26 (cos/cuz), tomorrow ×17 (tmr/tml), people ×11 (ppl),
словоформы says/asked/coming, апострофы (don't), склейки (may be).

Защита от перелечивания: выдуманное по-прежнему ловится («сын»,
food, airport — прежние фикстуры бегут своими замками).

Зеркало Swift — EntityGateTests («английская трассировка»).
Запуск: python3 tools/dictation_farm/test_entity_gate_en_tracing.py
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

    # сокращения источника разворачиваются пивотом — не выдумка
    ok &= check(gate("do u knw them or nt? may be ur frnds or classmates?",
                     "do you know them or not maybe your friends or "
                     "classmates ?") == [],
                "frnds→friends / may be→maybe флагуются")
    ok &= check("tomorrow" not in gate("so tmr wat time u can? i 1130 aft",
                                       "so tomorrow what time can you ?"),
                "tmr→tomorrow флагуется")
    ok &= check("because" not in gate("cant make it cos got class later",
                                      "i can't make it because i have "
                                      "class later"),
                "cos→because флагуется")
    ok &= check("people" not in gate("how many ppl are coming later",
                                     "how many people are coming later ?"),
                "ppl→people флагуется")

    # словоформы: пивот длиннее источника (says/asked/coming)
    ok &= check(gate("did she say when they come to ask about it",
                     "she says when they are coming to ask about it")
                == [],
                "says/coming (словоформы) флагуются")

    # апострофы: don't источника не сводился к dont пивота
    ok &= check("dont" not in gate("TIME IS VERY VALUEBLE,DON'T WASTE IT",
                                   "time is valuable dont waste it"),
                "don't→dont флагуется")

    # защита от перелечивания: несводимое остаётся флагом
    ok &= check("food" in gate("задержусь приболел по ходу немного",
                               "i am late and sick bring food"),
                "food без «еда» разлочен")
    ok &= check("theory" in gate("the boat is near the pier now today",
                                 "the boat is near the pier theory now"),
                "the→theory: служебное слово лицензировало выдумку")

    # Singlish-частицы — не имена: санитайзер понижает name_Liao до
    # слова; настоящее имя не трогается
    import pipeline as P
    ok &= check("name_" not in P.sanitize_pivot(
        "do you all reach name_Liao bo ?", codec),
        "частица liao осталась именем")
    ok &= check("name_Marina" in P.sanitize_pivot(
        "tell name_Marina we are late", codec),
        "настоящее имя пострадало от списка частиц")

    print("замки целы" if ok else "есть сломанные замки")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
