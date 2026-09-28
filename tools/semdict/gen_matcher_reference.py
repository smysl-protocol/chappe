# -*- coding: utf-8 -*-
"""Генератор эталона матчера: ios/Chappe/ChappeTests/matcher_reference.json.

Источники пивотов:
  - 12 эталонных диктовок dictation_corpus.jsonl (pivot_ref);
  - REGRESSION_PIVOTS — регрессия найденных в поле багов (28.07.2026:
    время «720 (am)», потерянный «20%»).

Swift-матчер (PivotMatcher) обязан давать те же юниты, байты и
разворот. Запуск: python3 gen_matcher_reference.py
"""
import json
import sys

sys.path.insert(0, ".")
from rm_codec import Codec
from pipeline import units_from_pivot

# Полевые баги 28.07.2026 (см. docs/dict_candidates.md, раздел «баги»):
REGRESSION_PIVOTS = [
    # время числом от модели + am; «(am)» больше не прилипает к чужому месту
    "we left earlier than planned currently 720 am we should be at the "
    "bridge in about 1 hour",
    # процент терялся токенизатором
    "i have 20% battery so writing short",
    # время с двоеточием цельным токеном, pm сдвигает на 12 часов
    "meet at 07:20 or better at 7:30 pm",
    # копула «i am» не тянет «до полудня»
    "i am not sure",
    # сумма: число + валюта одним юнитом esc_amount
    "take 200 dirhams in cash and 5 liters of water",
    # фразы-ритуалы v1.1 (esc_local): длиннейшее окно
    "good evening roger will call back i am in place",
    # П4: зацикливание модели — повтор схлопывается до одного
    "he needs help needs help needs help needs help come fast.",
    # «0720» без двоеточия (реальный пивот бенча детерминизма 28.07):
    # ведущий ноль в 3-4 цифрах — однозначно время
    "we left earlier than planned currently 0720 will be at the bridge "
    "in about 1 hour",
]


def main():
    codec = Codec()
    corpus = [json.loads(line)
              for line in open("dictation_corpus.jsonl", encoding="utf-8")]
    corpus += [json.loads(line)
               for line in open("sos_corpus.jsonl", encoding="utf-8")]
    pivots = [m["pivot_ref"] for m in corpus] + REGRESSION_PIVOTS

    vectors = []
    for pivot in pivots:
        units = units_from_pivot(pivot, codec)
        blob = codec.encode(units)
        assert codec.decode(blob) == units, f"roundtrip: {pivot}"
        vectors.append(dict(pivot=pivot,
                            units=[[k, v] for k, v in units],
                            hex=blob.hex(),
                            rendered=codec.render(units)))

    out = "../../ios/Chappe/ChappeTests/matcher_reference.json"
    json.dump(dict(vectors=vectors), open(out, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print(f"эталон матчера: {len(vectors)} векторов -> {out}")


if __name__ == "__main__":
    main()
