# -*- coding: utf-8 -*-
"""Полный конвейер R+M: диктовка → пивот → коды → байты → эфир → разворот RU.

Бэкенды раскладчика (стадия «диктовка → чистый пивот»):
  --backend offline   эталонные пивоты из корпуса (роль модели сыграна Claude
                      при составлении; для отладки харнесса и кодека)
  --backend llama     локальный llama-server (Qwen3-4B) OpenAI-совместимый:
                      python3 pipeline.py --backend llama --url http://127.0.0.1:8080
  --backend anthropic Anthropic API (нужен ANTHROPIC_API_KEY в окружении)

Стадия «пивот → коды» ДЕТЕРМИНИРОВАНА (фразовый матчер, не модель) — по
архитектуре §5: модель только готовит текст, транспорт — таблица.
"""
import json, math, re, sys, argparse, urllib.request
import zstandard as zstd
from coverage_test import phrase_index, lemma_candidates, match_word, TOKEN_RE
from rm_codec import Codec

PIVOT_PROMPT_TEMPLATE = """You convert dictated Russian speech (raw speech-to-text: no punctuation, filler words, self-corrections) into ONE line of minimal clean English pivot for a semantic codec.

HARD RULES:
1. Output exactly one line, nothing else. No "EN:", no explanations.
2. Short common English words, all lowercase.
3. ALL numbers as digits: write 6, not six. Times as digits: "at 6", "at 8 in the evening".
4. Keep every fact: numbers, times, dates, places, names, quantities, needs. Apply self-corrections ("в пятницу то есть в субботу" -> saturday only). Drop fillers (ну, короче, слушай, эээ, блин) and repeats.
5. Proper names: NAME:Mark.
6. Special underscore codes: use ONLY codes from this list, spelled exactly:
{codes}
Never invent codes or snake_case words. If no code fits, use plain words.
7. sos_active ONLY when people are in danger or injured and urgently need help RIGHT NOW. Broken equipment, empty fuel, dead battery, closed road, bad weather, radio checks are NOT sos. sos_cancel ONLY to cancel a previously sent alarm.

Examples:
RU: ну я это самое буду минут через десять наверное
EN: be there soon in 10 minutes
RU: слушай генератор сломался бензина нет купи литров пять
EN: the generator is broken no petrol buy 5 liters
RU: блин телефон почти сел если пропаду выйду на связь в девять
EN: state_battery_low i will be on the radio at 9
RU: прием прием как слышно это саша
EN: radio check can you hear me this is NAME:Sasha
RU: волны сегодня здоровые лодки не пойдут
EN: waves are big boats do not go today
RU: у нас пожар в доме человек без сознания нужны спасатели срочно
EN: sos_active hazard_fire injury_unconscious need_rescue severity_critical loc_at_home"""

# Singlish-частицы: модель метит незнакомое как NAME:, частицы тона —
# не имена (NUS-замер 06.08). Понижаются санитайзером до слов.
SINGLISH_PARTICLES = {
    "lah", "leh", "lor", "liao", "meh", "hor", "sia", "sian", "wat",
    "oso", "haiz", "walao", "aiyo", "aiya", "hee", "bah", "gah",
}

NUMWORDS = {"zero":0,"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,
 "seven":7,"eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,"thirteen":13,
 "fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,
 "nineteen":19,"twenty":20,"thirty":30,"forty":40,"fifty":50,"sixty":60,
 "seventy":70,"eighty":80,"ninety":90}

def sanitize_pivot(p, codec):
    """Детерминированная страховка после модели: первая строка, числительные ->
    цифры (с составными: twenty five -> 25), выдуманный snake_case -> слова,
    am/pm -> маркеры. Не трогает валидные коды словаря и NAME:."""
    p = p.strip().splitlines()[0]
    p = re.sub(r"^\s*(en|pivot)\s*:\s*", "", p, flags=re.I)
    p = p.replace("NAME:", "name_").replace("Name:", "name_").replace("name:", "name_")
    toks = re.findall(r"[A-Za-z_']+|\d+|[.?!]", p)
    out, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t in ".?!":
            out.append(t); i += 1; continue
        if t.startswith("name_"):
            # Singlish-частицы — не имена (NUS 06.08: liao→name_Liao,
            # leh→name_Leh; рендер делал из частицы Имя с заглавной).
            # Понижаем до обычного слова — дальше он уйдёт литералом.
            if t[5:].lower() in SINGLISH_PARTICLES:
                out.append(t[5:].lower()); i += 1; continue
            out.append("name_" + t[5:]); i += 1; continue
        low = t.lower()
        if low in NUMWORDS:
            val = NUMWORDS[low]
            if val % 10 == 0 and 20 <= val <= 90 and i + 1 < len(toks) \
                    and toks[i+1].lower() in NUMWORDS and NUMWORDS[toks[i+1].lower()] < 10:
                val += NUMWORDS[toks[i+1].lower()]; i += 1
            out.append(str(val)); i += 1; continue
        if low == "rur":
            i += 1; continue          # мусор STT от «руб» — глотаем
        if low == "kg":
            out.append("kilogram"); i += 1; continue
        if low == "km":
            out.append("kilometer"); i += 1; continue
        if low in ("pm", "am"):
            out.append(low + "_marker"); i += 1; continue
        if "_" in low and (low not in codec.by_en
                or codec.entries[codec.by_en[low]].get("layer") == "protected"):
            out.extend(w for w in low.split("_") if w); i += 1; continue
        out.append(low); i += 1
    return " ".join(out)

OLD_PROMPT = """You convert dictated Russian speech (raw speech-to-text, no punctuation, with filler words and self-corrections) into a minimal clean English pivot for a semantic codec.

Rules:
1. Keep ALL facts: numbers, times, dates, places, names, quantities, injuries, needs.
2. Apply self-corrections: "в пятницу то есть не в пятницу в субботу" -> "on saturday".
3. Drop fillers (ну, короче, слушай, эээ, блин, значит, в общем) and repeats.
4. Lowercase, no punctuation, simple common words, present simple where possible.
5. Proper names: prefix with NAME: (e.g. NAME:Mark).
6. Emergency content: use codes sos_active / sos_cancel / injury_* / need_* / hazard_* / state_* / loc_* / severity_* when applicable.
7. Output ONLY the pivot line, nothing else.

Examples:
RU: ну я это самое буду минут через десять наверное
EN: be there soon in 10 minutes
RU: слушай купи хлеба два и молока когда пойдешь
EN: buy 2 bread and milk when you go
RU: у нас пожар в доме нужны спасатели срочно двое детей внутри
EN: sos_active hazard_fire loc_at_home need_rescue severity_critical 2 children inside"""

def call_llama(url, ru, prompt):
    req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions",
        data=json.dumps({"model": "local", "temperature": 0, "max_tokens": 120, "stop": ["\n"],
            "messages": [{"role": "system", "content": prompt},
                         {"role": "user", "content": "RU: " + ru + "\nEN:"}]}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()

def call_anthropic(ru, prompt):
    import os
    req = urllib.request.Request("https://api.anthropic.com/v1/messages",
        data=json.dumps({"model": "claude-sonnet-4-6", "max_tokens": 200,
            "system": prompt,
            "messages": [{"role": "user", "content": "RU: " + ru + "\nEN:"}]}).encode(),
        headers={"Content-Type": "application/json",
                 "anthropic-version": "2023-06-01",
                 "x-api-key": os.environ["ANTHROPIC_API_KEY"]})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["content"][0]["text"].strip()

# ------------------------------------------------------- пивот → единицы (детерм.)
# Стяжения -> развёрнутая форма: смысл собирается концептом + оператором
# (op_negation и т.п.), отдельных кодов для стяжений в словаре нет.
CONTRACTIONS = {
    "don't": "do not", "doesn't": "does not", "didn't": "did not",
    "can't": "can not", "cannot": "can not", "won't": "will not",
    "isn't": "is not", "aren't": "are not", "wasn't": "was not",
    "weren't": "were not", "haven't": "have not", "hasn't": "has not",
    "hadn't": "had not", "wouldn't": "would not", "couldn't": "could not",
    "shouldn't": "should not", "mustn't": "must not", "ain't": "is not",
    "i'm": "i am", "i'll": "i will", "i've": "i have", "i'd": "i would",
    "you're": "you are", "you'll": "you will", "you've": "you have",
    "we're": "we are", "we'll": "we will", "we've": "we have",
    "they're": "they are", "they'll": "they will", "it's": "it is",
    "that's": "that is", "there's": "there is", "he's": "he is",
    "she's": "she is", "let's": "let us", "what's": "what is",
}

def _collapse_repeats(units):
    out = units
    for n in range(4, 0, -1):
        res, i = [], 0
        while i < len(out):
            if i + n > len(out):
                res.append(out[i]); i += 1; continue
            gram = out[i:i + n]
            k = 1
            while out[i + k * n:i + (k + 1) * n] == gram:
                k += 1
            if k == 1:
                res.append(out[i]); i += 1   # скользящее окно, не прыжок
                continue
            res.extend(gram)
            if k < 3:
                res.extend(gram * (k - 1))
            i += n * k
        out = res
    return out


def _meridiem(h, m, toks, i):
    """am/pm после времени: вернуть (минуты суток, новый индекс)."""
    if i < len(toks) and toks[i] in ("am", "pm"):
        h = h % 12 + (12 if toks[i] == "pm" else 0)
        i += 1
    return h * 60 + m, i


_V11_INDEX = None    # first-word -> [(слова окна, phrase_id)], длинные раньше


def _v11_index(codec):
    global _V11_INDEX
    if _V11_INDEX is None:
        idx = {}
        for pid, p in codec.phrases.items():
            for m in p["match"]:
                words = m.split()
                idx.setdefault(words[0], []).append((words, pid))
        for k in idx:
            idx[k].sort(key=lambda t: -len(t[0]))
        _V11_INDEX = idx
    return _V11_INDEX


EMOJI_RE = None


def _emoji_re(codec):
    global EMOJI_RE
    if EMOJI_RE is None:
        alts = sorted(codec.emoji, key=len, reverse=True)
        EMOJI_RE = re.compile("|".join(re.escape(e) for e in alts))
    return EMOJI_RE


# Б5 (29.07): устойчивое выражение кодируется целиком или уходит
# литералом, но НИКОГДА по словам («turned out» → «повернул наружу»).
# Список пополняется по прогонам (см. dict_candidates.md).
IDIOMS_LIT = [
    ["turned", "out"], ["turn", "out"], ["turns", "out"],
    ["worked", "out"], ["figure", "out"], ["figured", "out"],
]

# Б6: вопросительная структура без знака — ставим границу-вопрос сами
QUESTION_STARTERS = {"how", "what", "where", "when", "why", "who",
                     "did", "do", "does", "are", "is", "can", "could",
                     "will", "would", "have", "has", "am", "was", "were"}


def units_from_pivot(pivot, codec):
    # эмодзи — отдельными юнитами до токенизации (латинская токенизация
    # их не видит): из таблицы v1.1 — emoji-юнит, вне таблицы — литерал
    emoji_units = []
    for m in re.finditer(
            r"(?:[\u2600-\u27BF\u2B00-\u2BFF\U0001F000-\U0001FAFF]"
            r"[\uFE0F\U0001F3FB-\U0001F3FF]?(?:\u200D"
            r"[\u2600-\u27BF\U0001F000-\U0001FAFF]"
            r"[\uFE0F\U0001F3FB-\U0001F3FF]?)*)", pivot):
        e = m.group(0)
        emoji_units.append(("emoji", e) if e in codec.emoji_index
                           else ("lit", e))
    toks = TOKEN_RE.findall(pivot.lower().replace("name:", "name_"))
    toks = [w for t in toks for w in CONTRACTIONS.get(t, t).split(" ")]
    units, i, resid_run = [], 0, []
    def flush():
        nonlocal resid_run
        if resid_run:
            units.append(("lit", " ".join(resid_run))); resid_run = []
    while i < len(toks):
        t = toks[i]
        if t.startswith("name_"):
            flush(); units.append(("name", t[5:].capitalize())); i += 1; continue
        if t in ".?!":
            flush()
            boundary = {".": "sent_end", "?": "sent_question",
                        "!": "sent_exclaim"}[t]
            units.append(("code", codec.by_en[boundary]))
            i += 1; continue
        if ":" in t and t.replace(":", "").isdigit():
            # токен HH:MM (TOKEN_RE) -> время суток; следом am/pm — учесть
            flush()
            h, m = map(int, t.split(":"))
            if h < 24 and m < 60:
                minutes, i = _meridiem(h, m, toks, i + 1)
                units.append(("time", minutes)); continue
            units.append(("num", int(t.replace(":", "")))); i += 1; continue
        if t == "%":
            # «20%» -> число + код percent (раньше % терялся токенизатором)
            flush(); units.append(("code", codec.by_en["percent"]))
            i += 1; continue
        if t.isdigit():
            flush()
            nxt = toks[i + 1] if i + 1 < len(toks) else None
            # Б4: «100 percent» / «1000 times» — усилитель, НЕ величина
            # («на 100% будем» ломалось в «в районе 100»). Измеримый
            # контекст (батарея и т.п.) оставляет число числом.
            measurable = {"battery", "charge", "level", "humidity",
                          "capacity", "score"}
            window = set(toks[max(0, i - 2):i + 3])
            if int(t) == 100 and nxt == "percent" \
                    and not (window & measurable):
                units.append(("code", codec.by_en["op_emphasis"]))
                i += 2
                continue
            if int(t) == 1000 and nxt in ("times", "time") \
                    and not (window & measurable):
                units.append(("code", codec.by_en["op_emphasis"]))
                i += 2
                continue
            # «число + валюта» -> сумма (esc_amount); слов валют в
            # словаре нет — механизм один, путей кодирования один
            iso = codec.CURRENCY_WORDS.get(nxt) if nxt else None
            if iso:
                units.append(("amount", (int(t), iso))); i += 2; continue
            # «720 am» / «7 pm» (модель пишет время числом) -> время суток
            if nxt in ("am", "pm"):
                n = int(t)
                if n <= 12:
                    minutes, i = _meridiem(n, 0, toks, i + 1)
                    units.append(("time", minutes)); continue
                if 100 <= n <= 1259 and n % 100 < 60:
                    minutes, i = _meridiem(n // 100, n % 100, toks, i + 1)
                    units.append(("time", minutes)); continue
            # «0720»: ведущий ноль в 3-4 цифрах — однозначно время
            # (количество с ведущим нулём не пишут)
            if t[0] == "0" and len(t) in (3, 4):
                n = int(t)
                if n // 100 < 24 and n % 100 < 60:
                    minutes, i = _meridiem(n // 100, n % 100, toks, i + 1)
                    units.append(("time", minutes)); continue
            units.append(("num", int(t))); i += 1; continue
        # Б5: идиома → литерал целиком (если её нет в словаре фразой)
        idiom = next((w for w in IDIOMS_LIT
                      if toks[i:i + len(w)] == w
                      and " ".join(w) not in codec.by_en), None)
        if idiom:
            flush()
            units.append(("lit", " ".join(idiom)))
            i += len(idiom)
            continue
        # фразы v1.1: длиннейшее совпадение выигрывает у словарных,
        # если оно длиннее (равная длина — словарный код старше)
        v11_hit = None
        for first in lemma_candidates(t):
            for words, pid in _v11_index(codec).get(first, []):
                L = len(words)
                w = toks[i:i+L]
                if len(w) == L and all(
                        any(c == words[j] for c in lemma_candidates(w[j]))
                        for j in range(L)):
                    v11_hit = (pid, L); break
            if v11_hit: break
        hit = None
        for first in lemma_candidates(t):
            for words, e in phrase_index.get(first, []):
                L = len(words)
                if L == 1: continue
                w = toks[i:i+L]
                if len(w) == L and all(
                        any(c == words[j] for c in lemma_candidates(w[j]))
                        for j in range(L)):
                    hit = (e, L); break
            if hit: break
        if v11_hit and (not hit or v11_hit[1] > hit[1]):
            flush(); units.append(("phrase", v11_hit[0])); i += v11_hit[1]; continue
        if hit:
            flush(); units.append(("code", hit[0]["code"])); i += hit[1]; continue
        e = match_word(t)
        if e:
            flush(); units.append(("code", e["code"]))
        else:
            resid_run.append(t)
        i += 1
    flush()
    # П4 (29.07): повтор n-граммы ≥3 раз подряд — зацикливание модели
    units = _collapse_repeats(units)
    # Б6: вопросительная структура без терминала — знак меняет смысл,
    # ставим границу-вопрос сами (STT даёт пунктуацию не всегда)
    def _is_boundary(u):
        return (u[0] == "code" and codec.entries[u[1]]["en"]
                in ("sent_end", "sent_question", "sent_exclaim"))
    # «do not …» — императив, не инверсия
    if units and not _is_boundary(units[-1]) and toks \
            and toks[0] in QUESTION_STARTERS \
            and not (len(toks) > 1 and toks[1] == "not"):
        units.append(("code", codec.by_en["sent_question"]))
    return units + emoji_units

# ------------------------------------------------------- прогон
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="offline",
                    choices=["offline", "llama", "anthropic"])
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    args = ap.parse_args()

    codec = Codec()
    allowed = sorted(e["en"] for e in codec.entries.values()
                     if e["layer"] in ("protected",))
    prompt = PIVOT_PROMPT_TEMPLATE.format(codes=", ".join(allowed))
    # П.2 предзаморозки: корпуса разделены. Чат-путь — санитайзер (П1,
    # protected недостижим), таргет 100%. SOS-путь — протекты разрешены
    # (это и есть их путь), таргет 100%. Смешивать пути нельзя: смешанная
    # метрика имела потолок 39/44 и не ловила регрессии.
    corpus = [("chat", json.loads(l)) for l in
              open("dictation_corpus.jsonl", encoding="utf-8")]
    corpus += [("sos", json.loads(l)) for l in
               open("sos_corpus.jsonl", encoding="utf-8")]
    cz = zstd.ZstdCompressor(level=19, write_content_size=False,
                             write_checksum=False, write_dict_id=False)
    rows = []
    tot = dict(utf8=0, zstd=0, ours=0, roundtrip_ok=0)
    facts = {"chat": [0, 0], "sos": [0, 0]}        # [ok, all]
    for path, item in corpus:
        ru = item["ru_dictation"]
        pivot = (item["pivot_ref"] if args.backend == "offline"
                 else call_llama(args.url, ru, prompt) if args.backend == "llama"
                 else call_anthropic(ru, prompt))
        pivot_raw = pivot
        if path == "chat":
            pivot = sanitize_pivot(pivot, codec)
        units = units_from_pivot(pivot, codec)
        blob = codec.encode(units)
        back = codec.decode(blob)
        rt = (back == units)
        rendered = codec.render(back)
        # проверка фактов: число считается сохранённым и внутри
        # time/amount-юнитов (часы/минуты, сумма)
        def num_kept(n):
            return ("num", n) in back \
                or any(k == "time" and (v // 60 == n or v % 60 == n)
                       for k, v in back) \
                or any(k == "amount" and v[0] == n for k, v in back)
        nums_ok = all(num_kept(n) for n in item["facts_num"])
        ru_ok = [f for f in item["facts_ru"] if f.lower() in rendered.lower()
                 or f.lower() in pivot.lower()]
        facts[path][1] += len(item["facts_num"]) + len(item["facts_ru"])
        facts[path][0] += (len(item["facts_num"]) if nums_ok else 0) + len(ru_ok)
        tot["roundtrip_ok"] += rt
        u8 = len(ru.encode()); zb = len(cz.compress(ru.encode()))
        tot["utf8"] += u8; tot["zstd"] += zb; tot["ours"] += len(blob)
        rows.append(dict(path=path, ru_dictation=ru, pivot=pivot,
                         pivot_raw=pivot_raw, bytes=len(blob),
                         hex=blob.hex(), rendered_ru=rendered, roundtrip=rt,
                         utf8=u8, zstd=zb,
                         units=[[k, v] for k, v in units]))
        print(f"\n▸ [{path}] {ru}")
        print(f"  пивот : {pivot}" + ("" if pivot == pivot_raw.lower().strip()
              else f"   [сырой: {pivot_raw}]"))
        print(f"  байты : {len(blob)}  (utf8 {u8}, zstd {zb})   roundtrip={'ok' if rt else 'FAIL'}")
        print(f"  экран : {rendered}")

    n = len(corpus)
    print("\n" + "=" * 60)
    print(f"Диктовок: {n}   roundtrip кодека: {tot['roundtrip_ok']}/{n}")
    print(f"Байт всего: диктовка utf8 {tot['utf8']}  zstd {tot['zstd']}  "
          f"наш {tot['ours']}  ({tot['utf8']/tot['ours']:.1f}x / "
          f"{tot['zstd']/tot['ours']:.1f}x)")
    print(f"Среднее: {tot['utf8']/n:.0f}Б → {tot['ours']/n:.1f}Б на сообщение")
    for path in ("chat", "sos"):
        ok, allf = facts[path]
        mark = "OK" if ok == allf else "РЕГРЕССИЯ (таргет 100%)"
        print(f"Факты [{path}]: {ok}/{allf}  {mark}")
    json.dump(dict(backend=args.backend, aggregate=tot,
                   facts={k: dict(ok=v[0], total=v[1])
                          for k, v in facts.items()},
                   rows=rows),
              open("pipeline_results.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    if any(v[0] != v[1] for v in facts.values()):
        raise SystemExit(1)   # регрессия фактов — красный выход для CI

if __name__ == "__main__":
    main()
