# -*- coding: utf-8 -*-
"""Сверка python-кодека с РУЧНЫМИ векторами (tests/rm_hand_vectors.json).

Вектора посчитаны вручную по docs/rm_wire_bitspec.md и НЕ
перегенерируются: расхождение = дефект кодека, не повод обновить файл.
Зеркало Swift-стороны — ChappeTests/HandVectorsTests.

Запуск: python3 tools/semdict/check_hand_vectors.py   (выход 0 = сходится)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rm_codec import Codec  # noqa: E402


def main():
    codec = Codec(os.path.join(HERE, "rm_dict_core_v0.json"))
    path = os.path.join(HERE, "..", "..", "tests", "rm_hand_vectors.json")
    data = json.load(open(path, encoding="utf-8"))

    ok = True
    if data["dict_version"] != codec.version:
        print(f"ОШИБКА: словарь v{codec.version}, вектора для "
              f"v{data['dict_version']} — нужен новый файл по новой "
              f"спеке, не перегенерация")
        ok = False
    wire_hash = codec.wire_blob(b"")[:4].hex()
    if wire_hash != data["table_hash_be"]:
        print(f"ОШИБКА: отпечаток {wire_hash} != {data['table_hash_be']}")
        ok = False

    for v in data["vectors"]:
        units = [tuple(u) for u in v["units"]]
        got = codec.encode(units).hex()
        if got != v["hex"]:
            print(f"ДЕФЕКТ КОДЕКА {v['name']}: encode {got} != рука "
                  f"{v['hex']}\n  вывод: {v['derivation']}")
            ok = False
        back = codec.decode(bytes.fromhex(v["hex"]))
        if back != units:
            print(f"ДЕФЕКТ КОДЕКА {v['name']}: decode дал {back}")
            ok = False

    print("ручные вектора:",
          f"{len(data['vectors'])}/{len(data['vectors'])} сходятся"
          if ok else "ЕСТЬ РАСХОЖДЕНИЯ")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
