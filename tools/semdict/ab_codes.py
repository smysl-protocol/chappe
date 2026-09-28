# -*- coding: utf-8 -*-
"""A/B: EN-пивот (A) против прямых кодов (B) — на существующих
фикстурах, без нового сбора данных (бриф 28.07, п.2).

Входы: chat-корпус (10 ru) + farm_fixtures (12) + все фикстуры с
потерями из farm-результатов (~493). Путь A: сохранённые
рендеры/пивоты фикстур (для chat-корпуса — pivot_ref offline);
латентность A замеряется свежим прогоном на 30 ru-входах.
Путь B: codes_path.encode_codes на каждом входе, латентность на всём.

Выход: codes_ab_results.json (+ по-групповые метрики).
"""
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FARM = os.path.join(HERE, "..", "dictation_farm")
sys.path.insert(0, HERE)
sys.path.insert(0, FARM)
os.chdir(HERE)

from codes_path import encode_codes                    # noqa: E402
from rm_codec import Codec                             # noqa: E402
from pipeline import units_from_pivot, sanitize_pivot  # noqa: E402
from fact_extractor import extract, delivered          # noqa: E402

codec = Codec()


def agg_new():
    return dict(n=0, semantic=0, text=0, facts_ok=0, facts_all=0,
                by_cat={}, tokens=0, latin=0, blob=0, invalid=0,
                lat_ms=[], invalid_inputs=0)


def account(agg, source, rendered, blob_len, invalid_tries=0):
    agg["semantic"] += 1
    agg["blob"] += blob_len
    agg["invalid"] += invalid_tries
    toks = [t for t in re.findall(r"[^\W\d_]+", rendered.lower())
            if len(t) >= 2]
    agg["tokens"] += len(toks)
    agg["latin"] += sum(1 for t in toks if re.search(r"[a-z]", t))
    for cat, _f, ok in delivered(extract(source), extract(rendered)):
        agg["facts_all"] += 1
        agg["facts_ok"] += ok
        b = agg["by_cat"].setdefault(cat, [0, 0])
        b[1] += 1
        b[0] += ok


def load_inputs():
    """[(group, source_text, a_rendered|None)]"""
    rows = []
    for line in open("dictation_corpus.jsonl", encoding="utf-8"):
        m = json.loads(line)
        pivot = sanitize_pivot(m["pivot_ref"], codec)
        units = units_from_pivot(pivot, codec)
        rows.append(("chat_ru", m["ru_dictation"],
                     codec.render(units), len(codec.encode(units))))
    seen = set()
    for path, group_of in (
            (os.path.join(HERE, "..", "..", "tests",
                          "farm_fixtures_2026-07-28.json"), None),
            (os.path.join(FARM, "farm_text_results_en.json"), "en"),
            (os.path.join(FARM, "farm_text_results.json"), "ru"),
            (os.path.join(FARM, "farm_voice_results.json"), "ru")):
        data = json.load(open(path))
        fixtures = data if isinstance(data, list) else data["fixtures"]
        for f in fixtures:
            key = f["input"][:80]
            if key in seen:
                continue
            seen.add(key)
            group = group_of or (
                "en" if f["corpus"] in ("nus_sms", "nps_chat") else "ru")
            rows.append((f"fx_{group}", f["input"], f["rendered"],
                         len(bytes.fromhex(f["blob_hex"]))))
    return rows


def main():
    rows = load_inputs()
    print(f"входов: {len(rows)}", flush=True)
    groups = {}
    b_lat_all = []
    fixtures_b = []
    for i, (group, source, a_rendered, a_blob) in enumerate(rows):
        g = groups.setdefault(group, dict(A=agg_new(), B=agg_new()))
        g["A"]["n"] += 1
        account(g["A"], source, a_rendered, a_blob)

        g["B"]["n"] += 1
        t0 = time.time()
        rb = encode_codes(source)
        ms = (time.time() - t0) * 1000
        g["B"]["lat_ms"].append(ms)
        b_lat_all.append(ms)
        if rb["outcome"] == "semantic":
            account(g["B"], source, rb["rendered"], len(rb["blob"]),
                    rb["invalid_tries"])
            if rb["invalid_tries"]:
                g["B"]["invalid_inputs"] += 1
        else:
            g["B"]["text"] += 1
            g["B"]["invalid"] += rb["invalid_tries"]
            g["B"]["invalid_inputs"] += 1
            fixtures_b.append(dict(group=group, input=source[:200],
                                   reason=rb["reason"]))
        if (i + 1) % 50 == 0:
            print(f"{i+1}/{len(rows)} (B ср. {sum(b_lat_all)/len(b_lat_all):.0f} мс)",
                  flush=True)

    # свежая латентность A на 30 ru-входах (модельный пивот)
    import run_farm as F
    a_lat = []
    ru_rows = [r for r in rows if r[0] in ("chat_ru", "fx_ru")][:30]
    for _g, source, _r, _b in ru_rows:
        t0 = time.time()
        F.pivot_for(source)
        a_lat.append((time.time() - t0) * 1000)

    out = dict(groups={}, a_latency_ms_fresh30=sorted(a_lat),
               b_text_fixtures=fixtures_b)
    for group, g in groups.items():
        rec = {}
        for tag in ("A", "B"):
            s = g[tag]
            lat = s["lat_ms"]
            rec[tag] = dict(
                n=s["n"], semantic=s["semantic"], text=s["text"],
                facts=(s["facts_ok"], s["facts_all"]),
                by_cat=s["by_cat"],
                pidgin=(s["latin"], s["tokens"]),
                blob_avg=s["blob"] / max(s["semantic"], 1),
                invalid_outputs=s["invalid"],
                invalid_inputs=s["invalid_inputs"],
                lat_ms_avg=sum(lat) / len(lat) if lat else None)
        out["groups"][group] = rec
    json.dump(out, open(os.path.join(HERE, "codes_ab_results.json"), "w",
                        encoding="utf-8"), ensure_ascii=False, indent=1)
    for group, rec in out["groups"].items():
        for tag in ("A", "B"):
            s = rec[tag]
            fo, fa = s["facts"]
            li, to = s["pidgin"]
            print(f"[{group} {tag}] n={s['n']} факты={fo/max(fa,1):.1%} "
                  f"пиджин={li/max(to,1):.1%} blob={s['blob_avg']:.1f} "
                  f"невалид.входов={s['invalid_inputs']}"
                  + (f" lat={s['lat_ms_avg']:.0f}мс" if s["lat_ms_avg"] else ""))
    print("A свежая латентность (30 ru): "
          f"{sum(a_lat)/len(a_lat):.0f} мс ср.")


if __name__ == "__main__":
    main()
