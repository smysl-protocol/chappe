# -*- coding: utf-8 -*-
"""Проверка отпечатков провода перед сборкой/заморозкой (WP6, 02.08).

Считает и сверяет с эталоном:
  - отпечаток основной таблицы Хаффмана (FNV-1a 32 по "{code}:{bits};"
    в каноническом порядке (bits, code), младший байт) — тот самый байт,
    что едет в проводе (wireBlob[0]);
  - отпечаток litchars-таблицы (FNV-1a 32 по "{cp}:{bits};" канонических
    длин символьного Хаффмана) — в провод НЕ едет, ловит разъезд
    litchars_v12.json между копиями tools/ и бандла;
  - побайтовое равенство словаря и litchars между tools/semdict и
    Resources/sophie_kb.

Выход 0 — всё сходится; 1 — расхождение (сборку/заморозку останавливать).
Запуск: python3 tools/semdict/check_fingerprints.py [--expect-dict EE]
        [--expect-lit XX]
"""
import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = os.path.join(HERE, "..", "..", "ios", "Chappe", "Chappe",
                      "Resources", "sophie_kb")

sys.path.insert(0, HERE)
from rm_codec import Codec  # noqa: E402


def fnv1a(items):
    h = 0x811C9DC5
    for s in items:
        for b in s.encode():
            h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h & 0xFF


def litchars_fingerprint(c):
    """Канонические длины символьного Хаффмана — из Codec (он строит их
    тем же алгоритмом, что Swift; сюда попадает и тай-брейк)."""
    lens = sorted((cp, bv[0]) for cp, bv in c.char_enc.items())
    return fnv1a(f"{cp}:{bits};" for cp, bits in lens), len(lens)


def file_equal(name):
    a = open(os.path.join(HERE, name), "rb").read()
    b = open(os.path.join(BUNDLE, name), "rb").read()
    return a == b, hashlib.sha256(a).hexdigest()[:16]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expect-dict", default=None)
    ap.add_argument("--expect-lit", default=None)
    args = ap.parse_args()

    ok = True
    c = Codec(os.path.join(HERE, "rm_dict_core_v0.json"))
    dict_fp = c.table_hash
    lit_fp, lit_n = litchars_fingerprint(c)
    print(f"словарь: отпечаток 0x{dict_fp:02X} "
          f"({len(c.entries)} записей, v{c.version})")
    print(f"litchars: отпечаток 0x{lit_fp:02X} ({lit_n} символов)")

    for name in ("rm_dict_core_v0.json", "litchars_v12.json"):
        same, digest = file_equal(name)
        print(f"{name}: tools ↔ бандл {'совпадают' if same else 'РАЗЪЕХАЛИСЬ'} "
              f"(sha256 {digest}…)")
        ok &= same

    if args.expect_dict is not None:
        want = int(args.expect_dict, 16)
        if dict_fp != want:
            print(f"ОШИБКА: отпечаток словаря 0x{dict_fp:02X} ≠ "
                  f"ожидаемого 0x{want:02X}")
            ok = False
    if args.expect_lit is not None:
        want = int(args.expect_lit, 16)
        if lit_fp != want:
            print(f"ОШИБКА: отпечаток litchars 0x{lit_fp:02X} ≠ "
                  f"ожидаемого 0x{want:02X}")
            ok = False

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
