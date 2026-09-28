# -*- coding: utf-8 -*-
"""Замер покрытия и сжатия: пивот-текст -> коды словаря -> байты.

Честность замера:
  - матчер жадный, фразы раньше одиночек (длиннейшее окно);
  - простая лемматизация суффиксами (s/es/ed/ing/'s), без модели;
  - числа -> esc_number (8 бит escape-хаффман + varint);
  - непокрытое -> остаток: считаем ДВЕ границы
      пессимизм: UTF-8 как есть,
      оптимизм: 5.5 бит/символ (энтропийная оценка коротких строк);
  - грамматические операторы не применяются (служебные слова матчатся
    как обычные смыслы) — это делает оценку строже, не мягче;
  - envelope-заголовок не считаем (одинаков для всех подходов).

Базлайны на РУССКОМ оригинале (то, что реально полетело бы без семантики):
  UTF-8, zstd-19, zstd-19 + словарь, обученный на этом же корпусе
  (последнее — фора в пользу zstd, отмечено в отчёте).
"""
import json, re, math, zstandard as zstd

DICT = json.load(open("rm_dict_core_v0.json", encoding="utf-8"))
by_en = {}
for e in DICT["entries"]:
    if e["layer"] == "grammar":
        continue
    by_en[e["en"]] = e

# фразовый индекс: первая словоформа -> список (кортеж слов, entry), длинные раньше
phrase_index = {}
for en, e in by_en.items():
    words = tuple(en.split())
    phrase_index.setdefault(words[0], []).append((words, e))
for k in phrase_index:
    phrase_index[k].sort(key=lambda t: -len(t[0]))

ESC_NUM = by_en["esc_number"]

IRREG = {"ate":"eat","went":"go","came":"come","took":"take","said":"say",
"saw":"see","made":"make","left":"leave","fell":"fall","told":"tell",
"gave":"give","bought":"buy","sent":"send","found":"find","woke":"wake",
"met":"meet","ran":"run","got":"get","spoke":"speak","brought":"bring",
"thought":"think","heard":"hear","held":"hold","kept":"keep","lost":"lose",
"paid":"pay","slept":"sleep","stood":"stand","sat":"sit","drove":"drive",
"flew":"fly","forgot":"forget","knew":"know","wrote":"write","broke":"break",
"chose":"choose","felt":"feel","caught":"catch","taught":"teach","wore":"wear",
"given":"give","taken":"take","gone":"go","seen":"see","done":"do","been":"be",
"written":"write","forgotten":"forget","gotten":"get","eaten":"eat",
"driven":"drive","flown":"fly","spoken":"speak","chosen":"choose","woken":"wake"}
SUFFIXES = ["'s", "s", "es", "ed", "ing", "er", "est"]
def lemma_candidates(w):
    yield w
    if w in IRREG:
        yield IRREG[w]
    for suf in SUFFIXES:
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            stem = w[: -len(suf)]
            yield stem
            if suf in ("ing", "ed") and len(stem) >= 3:
                yield stem + "e"            # coming -> come, closed -> close
                if stem[-1] == stem[-2]:
                    yield stem[:-1]         # robbed -> rob, planned -> plan
            if suf == "ies" if False else False:
                pass
    if w.endswith("ied") and len(w) > 4:
        yield w[:-3] + "y"           # replied -> reply
    if w.endswith("ies") and len(w) > 4:
        yield w[:-3] + "y"                   # cities -> city

def match_word(w):
    for cand in lemma_candidates(w):
        if cand in by_en and " " not in cand:
            return by_en[cand]
    return None

TOKEN_RE = re.compile(r"\d{1,2}:\d{2}|[a-z_']+|\d+|%|[.?!]")

def encode(pivot):
    toks = TOKEN_RE.findall(pivot.lower())
    i, units, residual = 0, [], []
    while i < len(toks):
        t = toks[i]
        if t.isdigit():
            n = int(t)
            varint = 1 if n < 128 else 2 if n < 16384 else 3
            units.append((f"NUM({n})", ESC_NUM["bits"] + varint * 8))
            i += 1
            continue
        hit = None
        for first in lemma_candidates(t):
            for words, e in phrase_index.get(first, []):
                L = len(words)
                if L == 1:
                    continue
                window = toks[i : i + L]
                if len(window) == L:
                    ok = all(
                        any(c == words[j] for c in lemma_candidates(window[j]))
                        for j in range(L)
                    )
                    if ok:
                        hit = (words, e, L)
                        break
            if hit:
                break
        if hit:
            words, e, L = hit
            units.append((e["en"], e["bits"]))
            i += L
            continue
        e = match_word(t)
        if e:
            units.append((e["en"], e["bits"]))
        else:
            residual.append(t)
        i += 1
    covered = sum(1 for u, b in units if not u.startswith("NUM"))
    total_content = covered + len(residual)
    bits = sum(b for _, b in units)
    res_str = " ".join(residual)
    res_utf8 = len(res_str.encode("utf-8"))
    if residual:
        res_utf8 += 2  # esc_literal + длина
    return {
        "units": units,
        "residual": residual,
        "coverage": covered / total_content if total_content else 1.0,
        "code_bits": bits,
        "bytes_pess": math.ceil(bits / 8) + res_utf8,
        "bytes_opt": math.ceil((bits + len(res_str) * 5.5 + (16 if residual else 0)) / 8),
    }

# ------------------------------------------------------------------ базлайны
if __name__ == "__main__":
    corpus = [json.loads(l) for l in open("corpus.jsonl", encoding="utf-8")]
    ru_texts = [m["ru"] for m in corpus]

    samples = [t.encode("utf-8") for t in ru_texts]
    zd = zstd.train_dictionary(4096, samples * 3)     # *3: train_dictionary требует объём
    c_plain = zstd.ZstdCompressor(level=19,
            write_content_size=False, write_checksum=False, write_dict_id=False)
    c_dict = zstd.ZstdCompressor(level=19, dict_data=zd,
            write_content_size=False, write_checksum=False, write_dict_id=False)

    rows, agg = [], dict(utf8=0, zstd=0, zstd_dict=0, ours_p=0, ours_o=0,
                         cov=0.0, units=0, resid_msgs=0)
    for m in corpus:
        r = encode(m["en"])
        utf8 = len(m["ru"].encode("utf-8"))
        z = len(c_plain.compress(m["ru"].encode("utf-8")))
        zdd = len(c_dict.compress(m["ru"].encode("utf-8")))
        rows.append(dict(ru=m["ru"], en=m["en"], utf8=utf8, zstd=z, zstd_dict=zdd,
                         ours_pess=r["bytes_pess"], ours_opt=r["bytes_opt"],
                         coverage=round(r["coverage"], 3),
                         units=[u for u, _ in r["units"]],
                         residual=r["residual"]))
        agg["utf8"] += utf8; agg["zstd"] += z; agg["zstd_dict"] += zdd
        agg["ours_p"] += r["bytes_pess"]; agg["ours_o"] += r["bytes_opt"]
        agg["cov"] += r["coverage"]; agg["units"] += len(r["units"])
        agg["resid_msgs"] += bool(r["residual"])

    n = len(corpus)
    print(f"Сообщений: {n}   средняя длина RU: {agg['utf8']/n:.0f} байт UTF-8")
    print(f"Покрытие словарём:        {100*agg['cov']/n:.1f}% смысловых токенов")
    print(f"Сообщений с остатком:     {agg['resid_msgs']}/{n}")
    print()
    print(f"{'подход':<26}{'всего байт':>11}{'ср/сообщ':>10}{'сжатие':>9}")
    def line(name, total):
        print(f"{name:<26}{total:>11}{total/n:>10.1f}{agg['utf8']/total:>8.1f}x")
    line("RU UTF-8 (как есть)", agg["utf8"])
    line("zstd-19", agg["zstd"])
    line("zstd-19 + словарь", agg["zstd_dict"])
    line("R+M коды (пессимизм)", agg["ours_p"])
    line("R+M коды (оптимизм)", agg["ours_o"])
    print()
    p190 = lambda b: max(1, math.ceil(b / 190))
    one_pkt = sum(1 for r in rows if r["ours_pess"] <= 190)
    print(f"В 1 пакет LoRa (190Б) влезает: {one_pkt}/{n} сообщений (у zstd: "
          f"{sum(1 for r in rows if r['zstd_dict'] <= 190)}/{n})")

    with open("coverage_results.json", "w", encoding="utf-8") as f:
        json.dump(dict(aggregate=agg, per_message=rows), f, ensure_ascii=False, indent=1)

    print("\n--- примеры разбора ---")
    for r in rows[:3] + rows[32:34]:
        print(f"\nRU : {r['ru']}")
        print(f"код: {' | '.join(r['units'])}")
        if r["residual"]:
            print(f"ост: {r['residual']}")
        print(f"    utf8={r['utf8']}  zstd+dict={r['zstd_dict']}  "
              f"наш={r['ours_pess']}–{r['ours_opt']}Б  покрытие={r['coverage']:.0%}")
