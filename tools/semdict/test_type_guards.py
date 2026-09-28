# -*- coding: utf-8 -*-
"""Замки пределов типов python-кодека (аудит 03.08).

Найденная тихая порча: encode(phrase(128)) декодировался как ЭМОДЗИ
(тег 0x80 занят маркером), следующий байт съедался — рассинхрон всего
остатка потока. Валидные id фраз на проводе — 0x00–0x7F
(docs/rm_wire_bitspec.md §3). Вторая асимметрия: ext(4096) молча
кодировался как ext(0) — битовая маска без проверки (Swift бросал).

Зеркало Swift — ChappeTests/TypeLimitGuardTests.
Запуск: python3 tools/semdict/test_type_guards.py  (выход 0 = замки целы)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rm_codec import Codec  # noqa: E402


def expect_raises(fn, label):
    try:
        fn()
    except ValueError:
        return True
    print(f"ЗАМОК СЛОМАН: {label} не дал честного отказа")
    return False


def main():
    c = Codec(os.path.join(HERE, "rm_dict_core_v0.json"))
    ok = True

    # фраза 127 — последний валидный id, круг цел
    blob = c.encode([("phrase", 127)])
    if c.decode(blob) != [("phrase", 127)]:
        print("ЗАМОК СЛОМАН: phrase(127) не сходится кругом")
        ok = False

    # фраза 128 — честный отказ (раньше: молча становилась эмодзи)
    ok &= expect_raises(lambda: c.encode([("phrase", 128)]), "phrase(128)")

    # расширение: 4094 — последний назначаемый; 4095 зарезервирован под
    # 16-битный каскад (решение владельца 03.08, реестр ext_registry.json,
    # спека §5.5) и кодироваться НЕ должен, пока каскада нет; 4096 — отказ
    blob = c.encode([("ext", 4094)])
    if c.decode(blob) != [("ext", 4094)]:
        print("ЗАМОК СЛОМАН: ext(4094) не сходится кругом")
        ok = False
    ok &= expect_raises(lambda: c.encode([("ext", 4095)]),
                        "ext(4095, резерв каскада)")
    ok &= expect_raises(lambda: c.encode([("ext", 4096)]), "ext(4096)")

    # реестр: существует, первая строка — резерв 4095
    import json
    reg = json.load(open(os.path.join(HERE, "ext_registry.json"),
                         encoding="utf-8"))
    rows = reg["registry"]
    if not rows or rows[0].get("index") != 4095:
        print("ЗАМОК СЛОМАН: резерв 4095 не первая строка реестра")
        ok = False

    print("замки пределов:", "целы" if ok else "СЛОМАНЫ")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
