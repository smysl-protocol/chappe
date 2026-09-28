# -*- coding: utf-8 -*-
"""Ферма: транскрипты с телефона (farm_recognized.json) → полный конвейер
(llama-server, temp 0, реплика Swift: чанкер+пивот+петля+гейты) → метрики
и отчёт docs/reports/dictation_farm.md.

Паритет реплики с Swift доказан тестами (кодек hex-в-hex, матчер,
санитайзер, splice-вектора)."""
import json, os, re, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))
os.chdir(os.path.join(HERE, "..", "semdict"))
from rm_codec import Codec
import pipeline as P

URL = "http://127.0.0.1:8080"
MARKERS = {"и","а","но","вот","потом","короче","ну","значит",
           "если","что","когда","чтобы","только","там","тут"}

LOOP_SYSTEM = """Ты сравниваешь смысл двух русских текстов и переписываешь второй.
Перепиши второй текст по-русски так, чтобы он передавал мысль первого: естественные формулировки, идиомы разворачивай по смыслу (ran out = закончилось), английские слова переводи, все числа, места и имена из первого сохрани точно. Не добавляй фактов. Если второй текст потерял важный факт первого — верни его.
Ответ — только переписанный текст, без пояснений."""

codec = Codec()
# П1 (28.07): чат-промпт БЕЗ protected-кодов — зеркало
# SemanticEncoder.chatPromptTemplate (менять синхронно).
# v2 (31.07): правило 9 — запрет новых сущностей, незнакомое литералом.
PROMPT = open(os.path.join(HERE, "..", "semdict",
    "pivot_prompt_chat_v2.txt"), encoding="utf-8").read().strip()

# --- лексикон (реплика SemanticEncoder.ruLexicon) ---
RU_WORDS, RU_PREFIXES, RU_PREFIXES3 = set(), set(), set()
for e in codec.entries.values():
    ru = e.get("ru")
    if not ru:
        continue
    for w in re.findall(r"[^\W\d_]+", ru.lower()):
        if len(w) >= 3:
            RU_WORDS.add(w)
            RU_PREFIXES.add(w[:4])
            RU_PREFIXES3.add(w[:3])

def chat(system, user, max_tokens, stop=None):
    payload = {"model": "local", "temperature": 0, "max_tokens": max_tokens,
               "messages": [{"role": "system", "content": system},
                            {"role": "user", "content": user}]}
    if stop:
        payload["stop"] = stop
    req = urllib.request.Request(URL + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()

def marker_form(w):
    return "".join(c for c in w.lower() if c.isalpha())

def word_chunks(text):
    words = text.split()
    if len(words) <= 20:
        return [text] if words else []
    out, start = [], 0
    while start < len(words):
        if len(words) - start <= 20:
            out.append(" ".join(words[start:])); break
        target = start + 15
        cut = target
        for delta in range(5):
            e2, l2 = target - delta, target + delta
            if marker_form(words[e2]) in MARKERS: cut = e2; break
            if delta > 0 and l2 < len(words) and marker_form(words[l2]) in MARKERS:
                cut = l2; break
        out.append(" ".join(words[start:cut])); start = cut
    return out

def sentences(text):
    out, cur = [], ""
    for ch in text:
        cur += ch
        if ch in ".!?…\n":
            s = cur.strip()
            if s: out.append(s)
            cur = ""
    if cur.strip(): out.append(cur.strip())
    return out

def chunks(text):
    out, cur, ln = [], [], 0
    def flush():
        nonlocal cur, ln
        if cur: out.append(" ".join(cur)); cur = []; ln = 0
    for s in sentences(text):
        if len(s.split()) > 25:
            flush(); out.extend(word_chunks(s)); continue
        if cur and (ln + len(s) > 250 or len(cur) == 3): flush()
        cur.append(s); ln += len(s)
    flush()
    return out

def pivot_words(p):
    return len([t for t in re.split(r"[^A-Za-z0-9]+", p) if t])

def pivot_for(text, extra_rule=None):
    needs = len(text) > 250 or len(text.split()) > 25
    pieces = chunks(text) if needs else [text]
    pivots = []
    for piece in pieces:
        extra = "Переведи ВСЁ, не объединяй и не сокращай.\n" if len(pieces) > 1 else ""
        if extra_rule: extra = extra_rule + extra
        mt = min(90, max(24, len(piece.split()) * 3))
        pv = chat(PROMPT, extra + "RU: " + piece + "\nEN:", mt, stop=["\n"])
        cw = len(piece.split())
        if len(pieces) > 1 and pivot_words(pv) < 0.4 * cw:
            stronger = ("Переведи КАЖДОЕ слово исходника. НИЧЕГО не пропускай, "
                        "не объединяй и не сокращай — перевод должен быть такой же длины.\n")
            pv = chat(PROMPT, stronger + "RU: " + piece + "\nEN:", mt, stop=["\n"])
            if pivot_words(pv) < 0.4 * cw:
                return None, len(pieces)
        pivots.append(pv)
    return " ".join(pivots), len(pieces)

def numbers_set(text):
    return set(int(m) for m in re.findall(r"\d+", text))

def lost_numbers(source, pivot):
    """Времена нормализуются: 730 в пивоте покрывает 7 и 30 (STT «07:30»)."""
    covered = set(numbers_set(pivot))
    for n in list(covered):
        if 100 <= n <= 2359 and n % 100 < 60:
            covered.add(n // 100); covered.add(n % 100)
    return numbers_set(source) - covered

def encode_pass(text):
    pv, nch = pivot_for(text)
    if pv is None: return None
    sp = P.sanitize_pivot(pv, codec)
    units = P.units_from_pivot(sp, codec)
    if not units: return None
    blob = codec.encode(units)
    if lost_numbers(text, sp): return None
    src_w = len([w for w in re.split(r"[^\w]+", text.lower())
                 if len(w) >= 3 and not w.isdigit()])
    if src_w >= 4 and pivot_words(sp) < 0.3 * src_w: return None
    lit = sum(len(u[1].encode()) for u in units if u[0] == "lit")
    if blob and lit / len(blob) >= 0.5: return None
    return {"pivot": sp, "units": units, "blob": blob,
            "rendered": codec.render(units), "chunks": nch}

def needs_loop(source, res):
    has_latin = any(c.isascii() and c.isalpha() for c in res["rendered"])
    has_lit = any(u[0] == "lit" for u in res["units"])
    return has_latin or has_lit or len(source.split()) > 15

def latin_metrics(rendered, units):
    names = {v.lower() for k, v in units if k == "name"}
    toks = [t for t in re.findall(r"[^\W\d_]+(?:'[^\W\d_]+)?", rendered.lower())
            if len(t) >= 2 and t not in names]
    latin = [t for t in toks if re.search(r"[a-z]", t)]
    dictw = [t for t in toks
             if t in RU_WORDS or (len(t) >= 3 and t[:3] in RU_PREFIXES3)]
    return toks, latin, dictw

def final_gate(rendered, units):
    toks, latin, dictw = latin_metrics(rendered, units)
    if len(toks) < 6: return None
    if len(latin) / len(toks) > 0.25: return "латиница >25%"
    if len(set(latin)) >= 3: return "≥3 латинских слов"
    if len(toks) >= 12 and len(dictw) / len(toks) < 0.6:
        return "словарных <60%"
    return None

def full_pipeline(source):
    t0 = time.time()
    first = encode_pass(source)
    if first is None:
        return {"outcome": "text", "reason": "конвейер/gate", "sec": time.time() - t0}
    field, res, looped = first["rendered"], first, False
    if needs_loop(source, first):
        rw = chat(LOOP_SYSTEM,
                  "Первый текст (исходник):\n" + source
                  + "\n\nВторой текст:\n" + first["rendered"]
                  + "\n\nПереписанный второй текст:",
                  min(300, len(source.split()) * 4 + 40)).replace("\n", " ").strip()
        if rw and rw != first["rendered"]:
            second = encode_pass(rw)
            if second and not lost_numbers(source, second["pivot"]):
                field, res, looped = rw, second, True
    gate = final_gate(field, res["units"])
    sec = time.time() - t0
    if gate:
        return {"outcome": "text", "reason": gate, "sec": sec,
                "field": field, "units": res["units"]}
    return {"outcome": "semantic", "field": field, "blob": len(res["blob"]),
            "units": res["units"], "pivot": res["pivot"], "looped": looped,
            "chunks": res["chunks"], "sec": sec}


def main():
    recognized = json.load(open(os.path.join(HERE, "farm_recognized.json"),
                                encoding="utf-8"))
    manifest = {m["file"]: m for m in json.load(
        open(os.path.join(HERE, "out", "manifest.json"), encoding="utf-8"))}
    corpus = [json.loads(l) for l in open("dictation_corpus.jsonl",
                                          encoding="utf-8") if l.strip()]
    facts = {f"corpus{i+1:02d}": set(item.get("facts_num", []))
             for i, item in enumerate(corpus)}
    facts["test1"] = {40, 7, 30, 3}
    facts["test2"] = {15, 9}
    facts["salad"] = set()

    rows = []
    residual = {}
    for r in recognized["results"]:
        fname = r["file"].removeprefix("farm_")
        meta = manifest.get(fname)
        if meta is None:
            continue
        name = meta["name"]
        text = r.get("text", "")
        row = {"file": fname, "name": name, "variant": meta["variant"],
               "recognized_chars": len(text), "recognize_ms": r.get("recognize_ms"),
               "recognize_path": r.get("path", "")}
        if not text.strip():
            row["outcome"] = "распознавание: отказ"
            rows.append(row); print(fname, "-> отказ распознавания"); continue
        result = full_pipeline(text)
        row.update({k: v for k, v in result.items() if k != "units"})
        expected = facts.get(name, set())
        if result["outcome"] == "semantic":
            got = numbers_set(result.get("pivot", ""))
            row["facts_ok"] = expected <= got
            toks, latin, _ = latin_metrics(result["field"], result["units"])
            row["latin_pct"] = round(100 * len(latin) / max(1, len(toks)))
            for k, v in result["units"]:
                if k == "lit":
                    for w in re.findall(r"[a-z][a-z']+", v.lower()):
                        if len(w) >= 2:
                            residual[w] = residual.get(w, 0) + 1
        rows.append(row)
        print(fname, "->", result["outcome"],
              f"({result.get('reason','')})" if result["outcome"] == "text" else
              f"blob={result.get('blob')} facts_ok={row.get('facts_ok')}")

    out = {"rows": rows,
           "residual_top": sorted(residual.items(),
                                  key=lambda kv: -kv[1])[:30]}
    json.dump(out, open(os.path.join(HERE, "farm_results.json"), "w",
                        encoding="utf-8"), ensure_ascii=False, indent=1)
    print("готово: farm_results.json,", len(rows), "строк")


if __name__ == "__main__":
    main()
