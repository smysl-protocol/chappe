# -*- coding: utf-8 -*-
"""Путь B: модель выдаёт КОДЫ словаря напрямую (эксперимент 28.07).

Схема: лексический префильтр (детерминированный, по ru- и en-колонкам
словаря) → срез 100–200 кандидатов + грамматика + escape-механизмы →
промпт (pivot_prompt_codes_v1.txt) → строгий разбор → валидатор →
до двух перегенераций → TEXT.

Главный риск: 4B путается в номерах кодов — доля невалидных выходов
ведётся отдельной метрикой.
"""
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rm_codec import Codec                     # noqa: E402

URL = "http://127.0.0.1:8080"
PROMPT = open(os.path.join(HERE, "pivot_prompt_codes_v1.txt"),
              encoding="utf-8").read().strip()

SLICE_MIN, SLICE_MAX = 100, 200

_codec = Codec()

# --- индексы префильтра (строятся один раз) -------------------------------
_RU_STEM_INDEX = {}     # стем(3/4) -> set(code)
_EN_STEM_INDEX = {}
_BY_FREQ = []           # коды по убыванию частоты (для добора)
for _e in sorted(_codec.entries.values(), key=lambda e: -e.get("freq", 0)):
    code = _e["code"]
    layer = _e["layer"]
    if layer in ("grammar", "escape", "protected"):
        continue        # грамматика/escape добавляются всегда; protected — П1
    _BY_FREQ.append(code)
    for w in re.findall(r"[а-яё]+", (_e.get("ru") or "").lower()):
        if len(w) >= 3:
            for stem in {w[:3], w[:4]}:
                _RU_STEM_INDEX.setdefault(stem, set()).add(code)
    for w in re.findall(r"[a-z]+", _e["en"].lower()):
        if len(w) >= 2:
            for stem in {w[:3], w[:4], w}:
                _EN_STEM_INDEX.setdefault(stem, set()).add(code)

_GRAMMAR = [e["code"] for e in _codec.entries.values()
            if e["layer"] == "grammar"]


def candidate_slice(text):
    """Детерминированный срез кандидатов под фразу."""
    hits = set()
    for w in re.findall(r"[а-яёa-z']+", text.lower()):
        if len(w) < 3:
            continue
        if re.match(r"[а-яё]", w):
            for stem in {w[:3], w[:4]}:
                hits |= _RU_STEM_INDEX.get(stem, set())
        else:
            for stem in {w[:3], w[:4], w, w.rstrip("s")}:
                hits |= _EN_STEM_INDEX.get(stem, set())
    # добор частотными связками до минимума, потолок — SLICE_MAX
    ordered = [c for c in _BY_FREQ if c in hits]
    if len(ordered) < SLICE_MIN:
        for c in _BY_FREQ:
            if c not in hits:
                ordered.append(c)
                if len(ordered) >= SLICE_MIN:
                    break
    ordered = ordered[:SLICE_MAX]
    return ordered + _GRAMMAR      # грамматические операторы — всегда


def slice_block(codes):
    lines = []
    for c in codes:
        e = _codec.entries[c]
        ru = (e.get("ru") or "-").split("/")[0]
        lines.append(f"C{c} {ru} | {e['en']}")
    return "\n".join(lines)


TOKEN_RE = re.compile(
    r"^(C\d+|NUM:\d+|TIME:\d{1,2}:\d{2}|AMT:\d+:[A-Z]{3}|"
    r"NAME:[A-Za-zА-Яа-яЁё\-']+|LIT:\S+)$")


def parse_output(line, allowed):
    """Строка модели -> units или (None, причина)."""
    units = []
    for token in line.strip().split():
        if not TOKEN_RE.match(token):
            return None, f"неразбираемый токен «{token[:30]}»"
        if token.startswith("C"):
            code = int(token[1:])
            if code not in _codec.entries:
                return None, f"код вне словаря C{code}"
            if code not in allowed:
                return None, f"код вне среза C{code}"
            units.append(("code", code))
        elif token.startswith("NUM:"):
            units.append(("num", int(token[4:])))
        elif token.startswith("TIME:"):
            h, m = map(int, token[5:].split(":"))
            if h > 23 or m > 59:
                return None, f"кривое время {token}"
            units.append(("time", h * 60 + m))
        elif token.startswith("AMT:"):
            _, n, iso = token.split(":")
            units.append(("amount", (int(n), iso)))
        elif token.startswith("NAME:"):
            units.append(("name", token[5:]))
        elif token.startswith("LIT:"):
            units.append(("lit", token[4:]))
    if not units:
        return None, "пустой выход"
    return units, None


def _chat(system, user, max_tokens=200):
    payload = {"model": "local", "temperature": 0,
               "max_tokens": max_tokens,
               "messages": [{"role": "system", "content": system},
                            {"role": "user", "content": user}],
               "stop": ["\n"]}
    req = urllib.request.Request(
        URL + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()


def encode_codes(text):
    """Полный путь B: срез → модель → разбор → валидатор →
    до двух перегенераций. Возвращает dict с units/blob/rendered или
    outcome=text + счётчиком invalid_tries."""
    codes = candidate_slice(text)
    allowed = set(codes)
    user = ("CANDIDATE SLICE:\n" + slice_block(codes)
            + "\n\nSource: " + text + "\nOutput:")
    invalid = 0
    last_reason = None
    for attempt in range(3):                    # 1 попытка + 2 перегенерации
        extra = "" if attempt == 0 else (
            f"\nPREVIOUS OUTPUT WAS INVALID ({last_reason}). "
            "Use ONLY tokens from the allowed grammar and codes "
            "present in the slice.")
        line = _chat(PROMPT + extra, user)
        units, reason = parse_output(line, allowed)
        if units is not None:
            blob = _codec.encode(units)
            return dict(outcome="semantic", units=units, blob=blob,
                        rendered=_codec.render(units),
                        invalid_tries=invalid, raw=line)
        invalid += 1
        last_reason = reason
    return dict(outcome="text", reason="валидатор: " + (last_reason or "?"),
                invalid_tries=invalid)


if __name__ == "__main__":
    demo = "Слушай, отбой по старому кафе, туда не идём. Возьми 200 дирхамов наличными, буду у моста в 7:30."
    r = encode_codes(demo)
    for k in ("outcome", "reason", "rendered", "invalid_tries", "raw"):
        if k in r:
            print(k + ":", r[k])
    if r["outcome"] == "semantic":
        print("units:", r["units"], "| blob:", len(r["blob"]), "Б")
