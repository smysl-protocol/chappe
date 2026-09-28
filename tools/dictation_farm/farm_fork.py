# -*- coding: utf-8 -*-
"""Ферма, п.5 — развилка: 200 английских SMS двумя путями.

Путь A (как в текстовом контуре): текст напрямую в матчер — меряет
МАТЧЕР и переводные таблицы.
Путь B (продуктовый): текст через пивот-модель (llama, промпт v1) →
санитайзер → матчер — модель нормализует сленг сама.

Разница по фактам и пиджину отвечает, нужен ли слой SMS-нормализации
в матчере вообще. Выход: farm_fork_results.json.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))
os.chdir(os.path.join(HERE, "..", "semdict"))

import re                                        # noqa: E402
import farm_text as FT                           # noqa: E402
import run_farm as F                             # noqa: E402
import pipeline as P                             # noqa: E402
from fact_extractor import extract, delivered    # noqa: E402

codec = FT.codec


def metrics(text, rendered, units, agg):
    toks = [t for t in re.findall(r"[^\W\d_]+", rendered.lower())
            if len(t) >= 2]
    agg["tokens"] += len(toks)
    agg["latin"] += sum(1 for t in toks if re.search(r"[a-z]", t))
    for cat, _f, ok in delivered(extract(text), extract(rendered)):
        agg["facts_all"] += 1
        agg["facts_ok"] += ok


def main():
    sms = FT.load_nus(limit=200)                  # детерминированный срез
    a = dict(n=0, facts_ok=0, facts_all=0, tokens=0, latin=0, text=0)
    b = dict(n=0, facts_ok=0, facts_all=0, tokens=0, latin=0, text=0)
    rows = []
    for i, text in enumerate(sms):
        ra = FT.en_pass(text)
        if ra:
            a["n"] += 1
            if ra["outcome"] == "text":
                a["text"] += 1
            metrics(text, ra["rendered"], ra["units"], a)
        pv, _n = F.pivot_for(text)
        rb = None
        if pv:
            sp = P.sanitize_pivot(pv, codec)
            units = P.units_from_pivot(sp, codec)
            if units:
                rendered = codec.render(units)
                rb = dict(pivot=sp, rendered=rendered)
                b["n"] += 1
                metrics(text, rendered, units, b)
            else:
                b["text"] += 1
        else:
            b["text"] += 1
        rows.append(dict(input=text,
                         direct=ra["rendered"] if ra else None,
                         piloted=rb["rendered"] if rb else None))
        if (i + 1) % 50 == 0:
            print(f"{i+1}/200…", flush=True)
    for name, agg in (("A напрямую", a), ("B через пивот", b)):
        fr = agg["facts_ok"] / agg["facts_all"] if agg["facts_all"] else 0
        pid = agg["latin"] / agg["tokens"] if agg["tokens"] else 0
        print(f"[{name}] n={agg['n']} факты={fr:.1%} пиджин={pid:.1%}")
    json.dump(dict(path_a=a, path_b=b, rows=rows),
              open(os.path.join(HERE, "farm_fork_results.json"), "w",
                   encoding="utf-8"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
