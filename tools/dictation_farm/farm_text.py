# -*- coding: utf-8 -*-
"""Ферма, текстовый контур (п.1а): тысячи входов, STT мимо.

EN-корпуса (NUS SMS, NPS Chat): текст = готовый пивот, модель не
нужна — прямое покрытие словаря и переводных таблиц на масштабе.
RU-корпус (Tatoeba, фильтр разговорных): полный конвейер через
llama-server (пивот + петля + гейты) — реплика Swift.

Выход: farm_text_results.json (метрики + фикстуры потерь).
"""
import glob
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = ("/tmp/chappe-scratch/"
           "ac1ac3f8-5a36-4044-80f1-1767947e71f7/scratchpad")
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))
os.chdir(os.path.join(HERE, "..", "semdict"))

from rm_codec import Codec                      # noqa: E402
import pipeline as P                            # noqa: E402
from fact_extractor import extract, delivered, classify_loss  # noqa: E402

codec = Codec()
PAYLOAD_PER_PACKET = 180        # полезных байт в пакете при лимите 200 Б


def en_pass(text):
    """EN-текст сразу как пивот: sanitize -> матчер -> кодек -> рендер."""
    pivot = text.lower()
    pivot = re.sub(r"\s+", " ", pivot).strip()
    if not pivot:
        return None
    sp = P.sanitize_pivot(pivot, codec)
    units = P.units_from_pivot(sp, codec)
    if not units:
        return None
    blob = codec.encode(units)
    lit_bytes = sum(len(u[1].encode()) for u in units if u[0] == "lit")
    outcome = "semantic"
    reason = None
    if blob and lit_bytes / len(blob) >= 0.5:
        outcome, reason = "text", "литералы >=50% блоба"
    return dict(pivot=sp, units=units, blob=blob,
                rendered=codec.render(units), outcome=outcome,
                reason=reason, lit_bytes=lit_bytes)


def facts_score(src_text, rendered):
    src = extract(src_text)
    dst = extract(rendered)
    return delivered(src, dst)


def run_en_corpus(name, texts, sample_fixtures, residual, tally):
    stats = dict(n=0, semantic=0, text=0, facts_ok=0, facts_all=0,
                 bytes=0, utf8=0, packets=0, latin_tokens=0, tokens=0,
                 by_cat={})
    for text in texts:
        r = en_pass(text)
        if r is None:
            continue
        stats["n"] += 1
        stats[r["outcome"]] += 1
        stats["bytes"] += len(r["blob"])
        stats["utf8"] += len(text.encode())
        stats["packets"] += max(1, -(-len(r["blob"]) // PAYLOAD_PER_PACKET))
        # пиджин-индекс: латинские токены в ru-рендере
        toks = [t for t in re.findall(r"[^\W\d_]+", r["rendered"].lower())
                if len(t) >= 2]
        stats["tokens"] += len(toks)
        stats["latin_tokens"] += sum(1 for t in toks
                                     if re.search(r"[a-z]", t))
        # residual: несловарные смыслы (lit-прогоны по словам)
        for kind, val in r["units"]:
            if kind == "lit":
                for w in val.split():
                    if len(w) >= 3 and not w.isdigit():
                        residual[w] = residual.get(w, 0) + 1
        checks = facts_score(text, r["rendered"])
        lost = [c for c in checks if not c[2]]
        for cat, f, ok in checks:
            stats["facts_all"] += 1
            stats["facts_ok"] += ok
            bucket = stats["by_cat"].setdefault(cat, [0, 0])
            bucket[1] += 1
            bucket[0] += ok
            if not ok:
                kind = classify_loss(f, cat, r["rendered"])
                key = "lost_" + kind
                stats[key] = stats.get(key, 0) + 1
                per = stats.setdefault("lost_by_cat", {}).setdefault(
                    cat, [0, 0])          # [artifact, real]
                per[0 if kind == "artifact" else 1] += 1
        if lost and len(sample_fixtures) < 400:
            sample_fixtures.append(dict(
                corpus=name, input=text, pivot=r["pivot"],
                units=[[k, v] for k, v in r["units"]],
                blob_hex=bytes(r["blob"]).hex(),
                rendered=r["rendered"],
                lost=[[c, str(f)] for c, f, ok in checks if not ok]))
        tally[name] = stats
    return stats


def load_nus(limit=None):
    path = os.path.join(SCRATCH, "smsCorpus_en_2015.03.09_all.xml")
    s = open(path, encoding="utf-8", errors="ignore").read()
    msgs = re.findall(r"<text>(.*?)</text>", s, re.S)
    msgs = [re.sub(r"&lt;.*?&gt;|&amp;\w+;", " ", m).strip()
            for m in msgs]
    msgs = [m for m in msgs if len(m.split()) >= 4]
    return msgs[:limit] if limit else msgs


def load_nps(limit=None):
    posts = []
    for f in glob.glob(os.path.join(SCRATCH, "nps_chat", "*.xml")):
        s = open(f, encoding="utf-8", errors="ignore").read()
        posts += re.findall(r"<Post[^>]*>(.*?)</Post>", s, re.S)
    posts = [re.sub(r"<.*?>", "", p).strip() for p in posts]
    # выкинуть системные JOIN/PART и адресацию юзеров
    posts = [re.sub(r"\d\d-\d\d-\w+User\d+", "", p).strip() for p in posts
             if p not in ("JOIN", "PART") and len(p.split()) >= 4]
    return posts[:limit] if limit else posts


def load_tatoeba(n=100):
    rows = []
    with open(os.path.join(SCRATCH, "rus_sentences.tsv"),
              encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                continue
            t = parts[2]
            w = t.split()
            if 6 <= len(w) <= 25 and not re.search(r"[A-Za-z]", t):
                rows.append(t)
    random.seed(1)                       # фиксированный сэмпл
    return random.sample(rows, n)


def ru_full_pipeline(texts, sample_fixtures, residual):
    """Полный конвейер (реплика Swift): прегейт -> пивот (llama) ->
    гейты -> кодек. Петля опущена: рендер приёмника от неё не зависит
    (петля правит текст ОТПРАВИТЕЛЯ), а факт-чекер сверяет рендер."""
    import run_farm as F                 # llama-клиент и chunker
    stats = dict(n=0, semantic=0, text=0, facts_ok=0, facts_all=0,
                 bytes=0, utf8=0, packets=0, latin_tokens=0, tokens=0,
                 by_cat={}, text_reasons={})
    for text in texts:
        stats["n"] += 1
        stats["utf8"] += len(text.encode())
        reason = pre_detect(text)
        r = None
        if reason is None:
            r = encode_with_reason(F, text)
            reason = r.get("reason") if isinstance(r, dict) else None
        if r is None or r.get("outcome") != "semantic":
            stats["text"] += 1
            key = reason or "конвейер"
            stats["text_reasons"][key] = stats["text_reasons"].get(key, 0) + 1
            continue
        stats["semantic"] += 1
        stats["bytes"] += len(r["blob"])
        stats["packets"] += max(1, -(-len(r["blob"]) // PAYLOAD_PER_PACKET))
        toks = [t for t in re.findall(r"[^\W\d_]+", r["rendered"].lower())
                if len(t) >= 2]
        stats["tokens"] += len(toks)
        stats["latin_tokens"] += sum(1 for t in toks
                                     if re.search(r"[a-z]", t))
        for kind, val in r["units"]:
            if kind == "lit":
                for w in val.split():
                    if len(w) >= 3 and not w.isdigit():
                        residual[w] = residual.get(w, 0) + 1
        checks = facts_score(text, r["rendered"])
        for cat, f, ok in checks:
            stats["facts_all"] += 1
            stats["facts_ok"] += ok
            bucket = stats["by_cat"].setdefault(cat, [0, 0])
            bucket[1] += 1
            bucket[0] += ok
            if not ok:
                kind = classify_loss(f, cat, r["rendered"])
                stats["lost_" + kind] = stats.get("lost_" + kind, 0) + 1
                per = stats.setdefault("lost_by_cat", {}).setdefault(
                    cat, [0, 0])
                per[0 if kind == "artifact" else 1] += 1
        lost = [c for c in checks if not c[2]]
        if lost and len(sample_fixtures) < 400:
            sample_fixtures.append(dict(
                corpus="tatoeba_ru", input=text, pivot=r["pivot"],
                units=[[k, v] for k, v in r["units"]],
                blob_hex=bytes(r["blob"]).hex(), rendered=r["rendered"],
                lost=[[c, str(f)] for c, f, ok in checks if not ok]))
    return stats


# --- реплика прегейта SemanticEncoder (порог 37%, имена, функц-формы,
#     нормализация опечаток до подсчёта — решение владельца 03.08) ---
RU_FUNCTION_FORMS = {
    "неё", "него", "ней", "нём", "ему", "ей", "ею", "ими", "ним", "ними",
    "нам", "вам", "нами", "вами", "тебе", "тебя", "меня", "мне", "мной",
    "нас", "вас", "его", "её", "их", "сам", "сама", "сами", "самому",
    "самой", "себе", "себя", "будет", "буду", "будем", "будешь",
    "будут", "будете", "был", "была", "были", "было", "есть", "нет",
    "чтобы", "потому", "поэтому", "если", "когда", "тогда", "здесь",
    "там", "тут", "этот", "эта", "это", "эти", "тот", "той", "том",
}
RU_WORDS, RU_PREFIXES = set(), set()
for _e in codec.entries.values():
    if _e.get("ru"):
        for _w in re.findall(r"[^\W\d_]+", _e["ru"].lower()):
            if len(_w) >= 3:
                RU_WORDS.add(_w)
                if len(_w) >= 4:
                    RU_PREFIXES.add(_w[:4])

# Английский лексикон — та же конструкция из en-колонки словаря
# (бриф 06.08: язык входа определяет колонку). Служебные слова —
# список гейта сущностей (пивот переводит их без потерь).
from entity_gate import FUNCTION_WORDS as EN_FUNCTION_FORMS  # noqa: E402
EN_WORDS, EN_PREFIXES = set(), set()
for _e in codec.entries.values():
    for _w in re.findall(r"[a-z]+", _e["en"].lower()):
        if len(_w) >= 3:
            EN_WORDS.add(_w)
            if len(_w) >= 4:
                EN_PREFIXES.add(_w[:4])

_REPEATS = re.compile(r"(.)\1{2,}")

# Слова лексикона по длинам — кандидаты расстояния 1 отличаются длиной
# не больше чем на 1
_RU_WORDS_BY_LEN = {}
for _w in RU_WORDS:
    _RU_WORDS_BY_LEN.setdefault(len(_w), []).append(_w)
_EN_WORDS_BY_LEN = {}
for _w in EN_WORDS:
    _EN_WORDS_BY_LEN.setdefault(len(_w), []).append(_w)

_LEX = dict(
    ru=(RU_WORDS, RU_PREFIXES, RU_FUNCTION_FORMS, _RU_WORDS_BY_LEN),
    en=(EN_WORDS, EN_PREFIXES, EN_FUNCTION_FORMS, _EN_WORDS_BY_LEN))


def dominant_script(text):
    """Язык входа по письму: перевес латинских букв над кириллицей —
    en, иначе ru (смешанное и пустое — ru, прежнее поведение)."""
    cyr = len(re.findall(r"[а-яё]", text.lower()))
    lat = len(re.findall(r"[a-z]", text.lower()))
    return "en" if lat > cyr else "ru"


def collapse_repeats(word):
    """Схлопывание повторов: 3+ одинаковых буквы подряд -> одна
    («жжжди» -> «жди»). Двойные буквы — законная орфография, не трогаем."""
    return _REPEATS.sub(r"\1", word)


def lexicon_covers(word, lang="ru"):
    """Слово покрыто лексиконом языка (точное, префикс-4 или служебная
    форма). Колонка словаря выбирается языком входа (бриф 06.08)."""
    words, prefixes, funcs, _ = _LEX[lang]
    return (word in words
            or (len(word) >= 4 and word[:4] in prefixes)
            or word in funcs)


def _dl1(a, b):
    """Расстояние Дамерау-Левенштейна <=1: замена, вставка, пропуск
    или перестановка соседних букв."""
    la, lb = len(a), len(b)
    if la == lb:
        diff = [i for i in range(la) if a[i] != b[i]]
        if len(diff) <= 1:
            return True
        return (len(diff) == 2 and diff[1] == diff[0] + 1
                and a[diff[0]] == b[diff[1]] and a[diff[1]] == b[diff[0]])
    if abs(la - lb) != 1:
        return False
    if la > lb:
        a, b = b, a
    i = 0                       # b длиннее на 1: одна вставка/пропуск
    while i < len(a) and a[i] == b[i]:
        i += 1
    return a[i:] == b[i + 1:]


def normalized_in_lexicon(word, lang="ru"):
    """Нормализация токена, не прошедшего лексикон (решение владельца
    03.08, docs/reports/pregate_analysis_2026-08-03.md): 1) схлопнуть
    повторы букв и попробовать лексикон снова; 2) расстояние
    Дамерау-Левенштейна 1 до ПОЛНОГО слова лексикона; токены <=3 букв
    расстоянием не лечатся (ложные срабатывания на предлогах).

    Кандидаты расстояния — только полные слова RU_WORDS, НЕ префиксное
    покрытие вариантов: правка, меняющая префикс-4, «лечит» любое слово
    в чужую словарную семью («заголовок» -> «заболовок» по префиксу
    «забо») и размывает лексический прегейт до пропуска техтекста
    (ломался замок screenMessageGoesText)."""
    collapsed = collapse_repeats(word)
    if collapsed != word and lexicon_covers(collapsed, lang):
        return True
    if len(collapsed) <= 3:
        return False
    by_len = _LEX[lang][3]
    for n in (len(collapsed) - 1, len(collapsed), len(collapsed) + 1):
        for cand in by_len.get(n, ()):
            if _dl1(collapsed, cand):
                return True
    return False


def pre_detect(text):
    digits = sum(c.isdigit() for c in text)
    letters = sum(c.isalpha() for c in text)
    if digits + letters and digits / (digits + letters) > 0.15:
        return "прегейт: много цифр"
    names = set()
    start = True
    for raw in text.split():
        first = next((c for c in raw if c.isalpha()), None)
        if first is None:
            continue
        w = "".join(c for c in raw if c.isalpha()).lower()
        if first.isupper() and not start and len(w) >= 3:
            names.add(w)
        start = any(c in ".!?" for c in raw)
    words = [w for w in re.findall(r"[а-яёa-z]+", text.lower())
             if len(w) >= 3 and w not in names]
    if len(words) < 4:
        return None
    # Выбор колонки словаря (уточнение владельца 06.08): язык НЕ
    # определяется — вариант А «объединение»: слово покрыто, если
    # покрыто ХОТЬ ОДНОЙ колонкой; смешанные («скинь tracking number
    # завтра») проходят естественно. Вариант Б (алфавит по доле букв)
    # оставлен под RM_PREGATE_MODE=script для замеров.
    if os.environ.get("RM_PREGATE_MODE") == "script":
        lang = dominant_script(text)
        covered = sum(1 for w in words
                      if lexicon_covers(w, lang)
                      or normalized_in_lexicon(w, lang))
    else:
        covered = sum(
            1 for w in words
            if lexicon_covers(w, "ru") or lexicon_covers(w, "en")
            or normalized_in_lexicon(w, "ru")
            or normalized_in_lexicon(w, "en"))
    if (len(words) - covered) / len(words) > 0.37:
        return "прегейт: вне лексикона >37%"
    return None


def encode_with_reason(F, text):
    pv, _n = F.pivot_for(text)
    if pv is None:
        return dict(outcome="text", reason="пивот: слишком короткий/отказ")
    sp = P.sanitize_pivot(pv, codec)
    units = P.units_from_pivot(sp, codec)
    if not units:
        return dict(outcome="text", reason="матчер: пустые юниты")
    blob = codec.encode(units)
    if F.lost_numbers(text, sp):
        return dict(outcome="text", reason="гейт: потеря чисел")
    src_w = len([w for w in re.split(r"[^\w]+", text.lower())
                 if len(w) >= 3 and not w.isdigit()])
    if src_w >= 4 and F.pivot_words(sp) < 0.3 * src_w:
        return dict(outcome="text", reason="гейт: пивот слишком короткий")
    lit = sum(len(u[1].encode()) for u in units if u[0] == "lit")
    if blob and lit / len(blob) >= 0.5:
        return dict(outcome="text", reason="гейт: литность >=50%")
    lang = dominant_script(text)   # рендер и гейт — язык получателя
    fg = final_gate(codec.render(units, lang=lang), units, lang=lang)
    if fg:
        return dict(outcome="text", reason="финальный гейт: " + fg)
    # гейт отрицаний: до двух перегенераций пивота, потом TEXT
    tries = 0
    while negation_gate(text, codec.render(units)) and tries < 2:
        tries += 1
        pv2, _ = F.pivot_for(text, extra_rule=NEG_HINT)
        if pv2 is None:
            break
        sp2 = P.sanitize_pivot(pv2, codec)
        units2 = P.units_from_pivot(sp2, codec)
        if units2 and not F.lost_numbers(text, sp2):
            sp, units, blob = sp2, units2, codec.encode(units2)
    ng = negation_gate(text, codec.render(units))
    if ng:
        return dict(outcome="text", reason=ng)
    return dict(outcome="semantic", pivot=sp, units=units, blob=blob,
                rendered=codec.render(units))


# --- гейт отрицаний (реплика SemanticEncoder, п.3 пост-фермы) ---
NEG_MARKERS_RENDER = {"не", "нет", "никогда", "нельзя", "отмена",
                      "отменяется", "not", "no", "never", "don't", "cancel"}
NEG_HINT = ("CRITICAL: the source contains a negation. Translate EVERY "
            "negation explicitly: «не X» -> «not X», keep the negated "
            "verb. Never drop or invert a negation.\n")


def neg_stem(w):
    for p in ("по", "под", "при", "за", "вы", "пере", "до", "на", "об",
              "с", "у"):
        if w.startswith(p) and len(w) - len(p) >= 2:
            w = w[len(p):]
            break
    return w[:3]


def source_negations(text):
    toks = re.findall(r"[а-яёa-z']+", text.lower())
    out = []
    for i, t in enumerate(toks):
        if t == "не" and i + 1 < len(toks) and len(toks[i + 1]) >= 2 \
                and toks[i + 1] != "не":
            out.append(("не", neg_stem(toks[i + 1])))
        elif t in ("нет", "никогда", "нельзя"):
            out.append((t, ""))
        elif t.startswith("отбо") or t.startswith("отмен"):
            out.append(("отмена", ""))
    return out


def negation_gate(source, rendered):
    negs = source_negations(source)
    if not negs:
        return None
    toks = re.findall(r"[а-яёa-z']+", rendered.lower())
    has_marker = any(t in NEG_MARKERS_RENDER for t in toks)
    negated_action = any(
        t in NEG_MARKERS_RENDER and t != "нет"
        and any(len(toks[j]) >= 3 and toks[j] not in NEG_MARKERS_RENDER
                for j in range(i + 1, min(i + 3, len(toks))))
        for i, t in enumerate(toks))
    for marker, action in negs:
        if marker == "отмена":
            if not any(t.startswith(("отмен", "отбо")) or
                       t in ("cancel", "cancelled") for t in toks):
                return "гейт отрицаний: потеряна отмена"
            continue
        if not has_marker:
            return "гейт отрицаний: отрицание пропало"
        if action:
            stem_found = any(neg_stem(t).startswith(action[:2])
                             or t.startswith(action) for t in toks)
            if not stem_found and not negated_action:
                return "гейт отрицаний: пропало действие"
    return None


def final_gate(rendered, units, lang="ru"):
    """«Чужое письмо» в рендере получателя: для ru-рендера — латиница
    (прежнее поведение), для en-рендера — кириллица (бриф 06.08 п.2:
    гейт обязан мерить рендер ЯЗЫКА ПОЛУЧАТЕЛЯ, а не ru всегда)."""
    names = {v.lower() for k, v in units if k == "name"}
    toks = [t for t in re.findall(r"[^\W\d_]+(?:'[^\W\d_]+)?",
                                  rendered.lower())
            if len(t) >= 2 and t not in names]
    if len(toks) < 6:
        return None
    foreign_re = r"[a-z]" if lang == "ru" else r"[а-яё]"
    foreign = {t for t in toks if re.search(foreign_re, t)}
    if len(foreign) >= 3:
        return "непереведённые слова"
    return None


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else "all"
    residual = {}
    fixtures = []
    tally = {}
    if only in ("all", "en"):
        print("NUS SMS…", flush=True)
        run_en_corpus("nus_sms", load_nus(), fixtures, residual, tally)
        print("NPS Chat…", flush=True)
        run_en_corpus("nps_chat", load_nps(), fixtures, residual, tally)
    if only in ("all", "ru"):
        print("Tatoeba RU (полный конвейер, llama)…", flush=True)
        tally["tatoeba_ru"] = ru_full_pipeline(load_tatoeba(100),
                                               fixtures, residual)
    top = sorted(residual.items(), key=lambda kv: -kv[1])[:100]
    out = dict(corpora=tally, residual_top100=top, fixtures=fixtures)
    # раздельные файлы: en-прогон не затирает ru-результаты (урок 28.07)
    suffix = "_en" if only == "en" else ""
    path = os.path.join(HERE, f"farm_text_results{suffix}.json")
    json.dump(out, open(path, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    for name, s in tally.items():
        pid = s["latin_tokens"] / s["tokens"] if s["tokens"] else 0
        fr = s["facts_ok"] / s["facts_all"] if s["facts_all"] else 0
        print(f"[{name}] n={s['n']} semantic={s['semantic']} "
              f"text={s['text']} факты={fr:.1%} пиджин={pid:.1%} "
              f"байт/сообщ={s['bytes']/max(s['semantic'],1):.1f}")
    print("итог:", path)


if __name__ == "__main__":
    main()
