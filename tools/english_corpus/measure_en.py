# -*- coding: utf-8 -*-
"""Замер кодека на английском корпусе (WP2 брифа 05.08, вторая сессия).

Корпус: tests/english_corpus/nus_sms_2015_sample3000.jsonl (NUS SMS,
права и жанр — README рядом). Словарь и таблицы НЕ трогаются.

ДВА СЛОЯ — не смешивать:
  слой 0 «продукт как есть»: лексический пре-гейт русский, весь
         английский вход режется «вне лексикона» до пивота — это
         замеряется этапом a и НЕ обходится молча;
  слой 1 «потенциал»: пре-гейт обойдён явно (única правка пути),
         остальной конвейер продовый — pivot_for → sanitize → units →
         гейты → finish-хвост → спасение. Отвечает на гипотезу
         «английский обслуживается лучше русского».

Этапы: sample (пересоздать выборку из XML) | a | b | report.
Запуск: llama-server :8080 для этапа b.
  python3 tools/english_corpus/measure_en.py a|b|report
"""
import json
import os
import re
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CORPUS = os.path.join(ROOT, "tests", "english_corpus",
                      "nus_sms_2015_sample3000.jsonl")
SCRATCH = os.environ.get(
    "RM_SCRATCH",
    "/tmp/chappe-scratch/"
    "1ab4fc13-76b8-4839-83ce-5bfba8a66430/scratchpad")
STAGE_A = os.path.join(SCRATCH, "en_stage_a.json")
STAGE_B = os.path.join(SCRATCH, "en_stage_b.jsonl")
# 06.08: после английского пре-гейта bypass не нужен — но старый
# чекпойнт (замер потенциала 05.08) не смешиваем с продуктовым
if os.environ.get("RM_EN_AFTER") == "1":
    STAGE_A = os.path.join(SCRATCH, "en_stage_a_after.json")
    STAGE_B = os.path.join(SCRATCH, "en_stage_b_after.jsonl")

sys.path.insert(0, os.path.join(ROOT, "tools", "live_corpus"))
sys.path.insert(0, os.path.join(ROOT, "tools", "dictation_farm"))
sys.path.insert(0, os.path.join(ROOT, "tools", "semdict"))


def load_rows():
    return [json.loads(line) for line in open(CORPUS, encoding="utf-8")]


def text_payload(text):
    raw = text.encode("utf-8")
    return 1 + min(len(raw), len(zlib.compress(raw, 9)))


# ---------------------------------------------------------------- этап A

def stage_a():
    import farm_text as FT
    rows = load_rows()
    bypass = os.environ.get("RM_EN_AFTER") != "1"
    short, pregated, candidates = [], {}, []
    for r in rows:
        if len(r["text"].split()) <= 4:
            short.append(r["seq"])
            continue
        reason = FT.pre_detect(r["text"])
        if reason is not None:
            pregated[reason] = pregated.get(reason, 0) + 1
            if bypass:
                candidates.append(r["seq"])   # слой «потенциал» (05.08)
        else:
            candidates.append(r["seq"])
    out = dict(total=len(rows), short=short, pregated=pregated,
               candidates=candidates)
    json.dump(out, open(STAGE_A, "w", encoding="utf-8"), ensure_ascii=False)
    print(f"всего {len(rows)}; коротких (≤4 слов, П3) {len(short)}; "
          f"пре-гейт (слой 0, продукт): {pregated}; "
          f"к слою 1 (LLM): {len(candidates)}")


# ---------------------------------------------------------------- этап B

def stage_b():
    import farm_text as FT
    import run_farm as F
    import pipeline as P
    import rescue_measure as RM
    from measure import encode_keep_units, finish_gates
    from entity_gate import untraced_entities
    codec = FT.codec
    ents_by_en = {e["en"].lower(): e.get("ru")
                  for e in codec.entries.values()}
    pairs = [(e["en"], e.get("ru")) for e in codec.entries.values()]

    a = json.load(open(STAGE_A, encoding="utf-8"))
    by_seq = {r["seq"]: r for r in load_rows()}
    done = set()
    if os.path.exists(STAGE_B):
        for line in open(STAGE_B, encoding="utf-8"):
            done.add(json.loads(line)["seq"])
    out = open(STAGE_B, "a", encoding="utf-8")
    t0, n = time.time(), 0
    for seq in a["candidates"]:
        if seq in done:
            continue
        text = by_seq[seq]["text"]
        rec = dict(seq=seq)
        try:
            r = encode_keep_units(FT, F, P, codec, text)
            if r["outcome"] != "semantic":
                rec.update(outcome="text", reason=r["reason"])
                if r.get("pivot"):
                    rec["pivot"] = r["pivot"]
                if r["reason"].startswith("гейт отрицаний"):
                    rec["rescue_from"] = "negation"
            else:
                unt = untraced_entities(text, r["pivot"], ents_by_en, pairs)
                if unt:
                    rec.update(outcome="text", reason="гейт сущностей",
                               pivot=r["pivot"], untraced=sorted(unt)[:6],
                               rescue_from="entity")
                elif (fin := finish_gates(RM, codec, text, r["units"])):
                    rec.update(outcome="text", reason=fin, pivot=r["pivot"])
                else:
                    rec.update(outcome="semantic", pivot=r["pivot"],
                               units=[[k, v] for k, v in r["units"]],
                               rendered=codec.render(r["units"]),
                               blob_wire=len(codec.wire_blob(
                                   codec.encode(r["units"]))))
            if rec.get("rescue_from"):
                units = r.get("units")
                if units is None:
                    rec["rescue"] = "нет юнитов"
                else:
                    rescue, why = RM.mixed_rescue(text, list(units))
                    if rescue is None:
                        rec["rescue"] = why
                    elif (fin := finish_gates(RM, codec, text, rescue[0])):
                        rec["rescue"] = "сборка: " + fin
                    else:
                        mixed, n_r, n_all = rescue
                        rec.update(outcome="rescued", rescued=[n_r, n_all],
                                   rendered=codec.render(mixed),
                                   blob_wire=len(codec.wire_blob(
                                       codec.encode(mixed))))
        except Exception as e:                       # noqa: BLE001
            rec.update(outcome="error", error=repr(e)[:200])
        out.write(json.dumps(rec, ensure_ascii=False) + "\n")
        out.flush()
        n += 1
        if n % 25 == 0:
            rate = n / (time.time() - t0)
            left = (len(a["candidates"]) - len(done) - n) / max(rate, 1e-9)
            print(f"[пульс] {n} за сессию, {len(done)+n}/"
                  f"{len(a['candidates'])}, ~{left/60:.0f} мин осталось",
                  flush=True)
    print("этап b готов:", STAGE_B)


# ------------------------------------------------------------- этап report

def stage_report():
    import farm_text as FT
    import mixed_mode_measure as MM
    codec = FT.codec
    a = json.load(open(STAGE_A, encoding="utf-8"))
    by_seq = {r["seq"]: r for r in load_rows()}
    b = {}
    for line in open(STAGE_B, encoding="utf-8"):
        d = json.loads(line)
        b[d["seq"]] = d

    tally, reasons = {}, {}
    for seq, rec in b.items():
        tally[rec["outcome"]] = tally.get(rec["outcome"], 0) + 1
        if rec["outcome"] == "text":
            reasons[rec["reason"].split(":")[0]] = \
                reasons.get(rec["reason"].split(":")[0], 0) + 1

    covs = []
    for seq, rec in b.items():
        if "pivot" in rec:
            cl = [x for x in MM.classify_tokens(rec["pivot"])
                  if x[1] != "punct"]
            if cl:
                cov = sum(1 for _t, st in cl
                          if st in ("code", "phrase", "num")) / len(cl)
                covs.append((cov, seq))
    covs.sort()

    # провод: слой 1 (semantic/rescued — блоб, прочее — текст) против
    # «всё текстом» (слой 0, продукт сегодня) и zstd со словарём
    import zstandard as zstd
    ordered = [r["seq"] for r in load_rows()]
    train = [by_seq[s]["text"].encode() for i, s in enumerate(ordered)
             if i % 10 < 7]
    hold = [s for i, s in enumerate(ordered) if i % 10 >= 7]
    zdict = zstd.train_dictionary(112640, [t for t in train if t])
    c_dict = zstd.ZstdCompressor(level=19, dict_data=zdict)
    comp = dict(utf8=0, zlib9=0, zstd19_dict=0, layer0_text=0,
                layer1=0, n=len(hold))
    for s in hold:
        t = by_seq[s]["text"]
        raw = t.encode()
        comp["utf8"] += len(raw)
        comp["zlib9"] += len(zlib.compress(raw, 9))
        comp["zstd19_dict"] += len(c_dict.compress(raw))
        comp["layer0_text"] += text_payload(t)
        rec = b.get(s)
        comp["layer1"] += (rec["blob_wire"]
                           if rec and rec.get("blob_wire")
                           and rec["outcome"] in ("semantic", "rescued")
                           else text_payload(t))

    examples = dict(semantic=[], gated_entities=[], rescued=[],
                    size_gate=[], missing=[])
    for seq, rec in sorted(b.items()):
        t = by_seq[seq]["text"]
        if rec["outcome"] == "semantic" and len(examples["semantic"]) < 12:
            examples["semantic"].append(
                dict(seq=seq, text=t[:90], pivot=rec["pivot"][:90],
                     rendered=rec["rendered"][:90],
                     wire=rec["blob_wire"], text_bytes=text_payload(t)))
        elif rec.get("reason") == "гейт сущностей" \
                and len(examples["gated_entities"]) < 10:
            examples["gated_entities"].append(
                dict(seq=seq, text=t[:90], flags=rec.get("untraced")))
        elif rec["outcome"] == "rescued" and len(examples["rescued"]) < 8:
            examples["rescued"].append(
                dict(seq=seq, text=t[:90], rendered=rec["rendered"][:90]))
        elif rec.get("reason", "").startswith("гейт размера") \
                and len(examples["size_gate"]) < 8:
            examples["size_gate"].append(
                dict(seq=seq, text=t[:70], pivot=rec.get("pivot", "")[:70]))
        elif rec.get("reason", "").startswith("гейт пропажи") \
                and len(examples["missing"]) < 10:
            examples["missing"].append(
                dict(seq=seq, text=t[:90], reason=rec["reason"][:90]))

    def pct(x):
        return f"{x[0]:.0%}"

    print(json.dumps(dict(
        layer0=dict(total=a["total"], short=len(a["short"]),
                    pregated=a["pregated"]),
        layer1_tally=tally, text_reasons=reasons,
        coverage=dict(n=len(covs),
                      median=pct(covs[len(covs) // 2]) if covs else "—",
                      p10=pct(covs[len(covs) // 10]) if covs else "—",
                      worst=[(pct(c), c[1]) for c in covs[:10]]),
        compressors=comp, examples=examples), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    {"a": stage_a, "b": stage_b, "report": stage_report}[sys.argv[1]]()
