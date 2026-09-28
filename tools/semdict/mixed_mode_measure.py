# -*- coding: utf-8 -*-
"""Этап 1 смешанного режима (долг 5) — замер, 05.08.2026.

Не для решения «делать ли» (решение владельца принято), а чтобы знать,
ЧТО чинить: где теряются длинные предложения, сколько сообщений падает
в текст из-за одного-двух слов, лексика виновата или операторы, и что
даст смешанный режим при разной гранулярности.

Корпуса — все, где есть пара (текст, пивот):
  - tools/semdict/dictation_corpus.jsonl (живые диктовки, pivot_ref)
  - tools/semdict/sos_corpus.jsonl
  - tests/farm_fixtures_2026-07-28.json (12 фикстур фермы с пивотами)
Полевой корпус (manifest.json) и tatoeba пивотов не содержат — в замер
покрытия не входят; это честное ограничение, записано в отчёте.

Запуск: python3 tools/semdict/mixed_mode_measure.py
Вывод: markdown в stdout (перенаправить в docs/reports/).
"""
import json
import os
import re
import sys
import zlib
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from coverage_test import lemma_candidates, match_word, phrase_index  # noqa: E402
from rm_codec import Codec  # noqa: E402

codec = Codec(os.path.join(HERE, "rm_dict_core_v0.json"))

TOKEN_RE = re.compile(r"\d{1,2}:\d{2}|[a-z_']+|\d+|%|[.?!]")

# Операторы, которых в словаре «нет вообще» (бриф): отрицание, условие,
# приблизительность + модальность. Проверяется по факту match_word.
OPERATOR_TOKENS = {
    "not", "no", "never", "cannot", "can't", "don't", "didn't", "won't",
    "if", "unless", "when", "whether",
    "about", "approximately", "around", "roughly", "almost", "nearly",
    "maybe", "probably", "possibly", "perhaps", "likely",
    "would", "could", "should", "might", "must",
}


def load_corpora():
    out = []
    with open(os.path.join(HERE, "dictation_corpus.jsonl")) as f:
        for line in f:
            d = json.loads(line)
            out.append(("dictation", d["ru_dictation"], d["pivot_ref"]))
    with open(os.path.join(HERE, "sos_corpus.jsonl")) as f:
        for line in f:
            d = json.loads(line)
            out.append(("sos", d.get("ru_dictation", ""),
                        d.get("pivot_ref", "")))
    fx = json.load(open(os.path.join(HERE, "..", "..", "tests",
                                     "farm_fixtures_2026-07-28.json")))
    for d in fx:
        out.append((f"farm:{d['corpus']}", d["input"], d["pivot"]))
    return [(src, ru, pv) for src, ru, pv in out if pv]


# --- пословный разбор пивота: покрыто/число/оператор/лексика ---------------

def classify_tokens(pivot):
    """[(токен, статус)]: status ∈ code|phrase|num|op|lex; знаки — отдельно."""
    toks = TOKEN_RE.findall(pivot.lower())
    result = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in ".?!":
            result.append((t, "punct"))
            i += 1
            continue
        if t.isdigit() or ":" in t:
            result.append((t, "num"))
            i += 1
            continue
        hit_len = 0
        for first in lemma_candidates(t):
            for words, _e in phrase_index.get(first, []):
                L = len(words)
                if L == 1:
                    continue
                window = toks[i:i + L]
                if len(window) == L and all(
                        any(c == words[j] for c in lemma_candidates(window[j]))
                        for j in range(L)):
                    hit_len = L
                    break
            if hit_len:
                break
        if hit_len:
            for w in toks[i:i + hit_len]:
                result.append((w, "phrase"))
            i += hit_len
            continue
        if match_word(t) is not None:
            result.append((t, "code"))
        elif t in OPERATOR_TOKENS:
            result.append((t, "op"))
        else:
            result.append((t, "lex"))
        i += 1
    return result


def split_sentences(classified):
    sents, cur = [], []
    for tok, st in classified:
        if st == "punct":
            if cur:
                sents.append(cur)
                cur = []
        else:
            cur.append((tok, st))
    if cur:
        sents.append(cur)
    return sents


# --- байты вариантов -------------------------------------------------------

SENT_END = None
for _code, _e in codec.entries.items():
    if _e.get("en") == "sent_end":
        SENT_END = _code
        break


def units_word_level(classified):
    """Смешение на уровне слов: непокрытое — esc_literal самим словом."""
    units = []
    for tok, st in classified:
        if st == "punct":
            if SENT_END is not None:
                units.append(("code", SENT_END))
        elif st == "num":
            units.append(("num", int(tok.split(":")[0]) if ":" in tok
                          else int(tok)))
        elif st in ("code", "phrase"):
            # для замера достаточно первого совпавшего кода слова
            e = match_word(tok)
            units.append(("code", e["code"]) if e else ("lit", tok))
        else:
            units.append(("lit", tok))
    return units


def units_granular(sents, level):
    """Смешение по предложениям или фразам: участок с непокрытым словом
    целиком уходит вербатимом (esc_literal), чистый — кодами."""
    units = []
    for sent in sents:
        chunks = [sent] if level == "sentence" else chunk_phrases(sent)
        for chunk in chunks:
            clean = all(st in ("code", "phrase", "num") for _t, st in chunk)
            if clean:
                units.extend(units_word_level(chunk))
            else:
                units.append(("lit", " ".join(t for t, _s in chunk)))
        if SENT_END is not None:
            units.append(("code", SENT_END))
    return units


def chunk_phrases(sent, size=4):
    """Фразовая гранулярность: за неимением синтаксиса — окна по size
    слов (нижняя оценка выигрыша: настоящие фразовые границы лучше)."""
    return [sent[i:i + size] for i in range(0, len(sent), size)]


def wire_bytes(units):
    try:
        return len(codec.wire_blob(codec.encode(units)))
    except Exception:
        return None


def text_bytes(ru):
    raw = ru.encode("utf-8")
    z = zlib.compress(raw, 9)
    return 1 + min(len(raw), len(z))     # [кодек][данные], меньший из store/zlib


# --- главный проход --------------------------------------------------------

def main():
    corpora = load_corpora()
    by_len = defaultdict(list)           # длина предложения → доли покрытия
    text_only_because = Counter()        # сколько непокрытых слов у сообщений
    uncovered = Counter()
    uncovered_ops = Counter()
    rows = []

    for src, ru, pivot in corpora:
        cl = classify_tokens(pivot)
        words = [x for x in cl if x[1] != "punct"]
        covered = [x for x in words if x[1] in ("code", "phrase", "num")]
        n_unc = len(words) - len(covered)
        for tok, st in words:
            if st == "lex":
                uncovered[tok] += 1
            elif st == "op":
                uncovered_ops[tok] += 1
        for sent in split_sentences(cl):
            if sent:
                frac = sum(1 for _t, s in sent
                           if s in ("code", "phrase", "num")) / len(sent)
                by_len[len(sent)].append(frac)
        text_only_because[min(n_unc, 3)] += 1

        b_text = text_bytes(ru)
        b_word = wire_bytes(units_word_level(cl))
        sents = split_sentences(cl)
        b_sent = wire_bytes(units_granular(sents, "sentence"))
        b_phr = wire_bytes(units_granular(sents, "phrase"))
        rows.append((src, len(words), n_unc, b_text, b_word, b_phr, b_sent))

    print("## Замер смешанного режима — сырые числа\n")
    print(f"Сообщений с пивотами: {len(corpora)} "
          "(диктовки 10, SOS 2, фикстуры фермы 12)\n")

    print("### Покрытие по длине предложения (пивот, словарь v1.3.0)\n")
    print("| Слов в предложении | Предложений | Средняя доля покрытых | Полностью покрытых |")
    print("|---|---|---|---|")
    bins = [(1, 3), (4, 6), (7, 10), (11, 15), (16, 99)]
    for lo, hi in bins:
        fr = [f for L, fs in by_len.items() if lo <= L <= hi for f in fs]
        if not fr:
            continue
        full = sum(1 for f in fr if f == 1.0)
        print(f"| {lo}–{hi} | {len(fr)} | {sum(fr)/len(fr):.0%} | "
              f"{full}/{len(fr)} |")

    print("\n### Из-за скольких слов сообщение целиком уходит текстом\n")
    print("| Непокрытых слов | Сообщений |")
    print("|---|---|")
    for k in sorted(text_only_because):
        label = {0: "0 (покрыто всё)", 1: "1", 2: "2", 3: "3+"}[k]
        print(f"| {label} | {text_only_because[k]} |")

    print("\n### Что роняет: операторы против лексики\n")
    n_op = sum(uncovered_ops.values())
    n_lex = sum(uncovered.values())
    print(f"Непокрытых вхождений всего: {n_op + n_lex}; "
          f"операторы: {n_op}; лексика: {n_lex}\n")
    print("Операторы:", ", ".join(f"{w}×{c}" for w, c
                                  in uncovered_ops.most_common()) or "—")
    print()
    print("Лексика (топ-15):", ", ".join(
        f"{w}×{c}" for w, c in uncovered.most_common(15)) or "—")

    print("\n### Байты по гранулярности (пивот; вербатим-участки — текстом пивота)\n")
    print("| Корпус | Слов | Непокр. | Текст (сейчас) | Слова (лит-слово) | Фразы (окно 4) | Предложения |")
    print("|---|---|---|---|---|---|---|")
    tot = [0, 0, 0, 0]
    for src, n, unc, bt, bw, bp, bs in rows:
        print(f"| {src} | {n} | {unc} | {bt} | {bw} | {bp} | {bs} |")
        for i, v in enumerate((bt, bw, bp, bs)):
            if v:
                tot[i] += v
    print(f"| **сумма** | | | **{tot[0]}** | **{tot[1]}** | "
          f"**{tot[2]}** | **{tot[3]}** |")


if __name__ == "__main__":
    main()
