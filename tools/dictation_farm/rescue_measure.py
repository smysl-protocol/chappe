# -*- coding: utf-8 -*-
"""Замер сегментного спасения (долг 5, этап 3) на живом материале.

Зеркалит Swift mixedRescue (SemanticEncoder.swift, коммит 5c957a4):
разбиение источника по предложениям, юнитов — по sent_end/…, строгое
выравнивание 1:1, пер-предложенческие гейты (несводимое существительное
по ru-колонке кодов + негации + финальный порог), вербатим-оригинал в
esc_literal, перепроверка целого после сборки.

Корпус — живой материал, сохранившийся в git: 15 полевых карточек
(manifest полевого корпуса), 10 живых диктовок, «иди к лодочной
станции» (единственный сохранившийся текст ночного корпуса 02.08 —
остальные 11 текстов в git не записаны, только агрегаты отчёта; та же
потеря класса tatoeba, сказано честно).

Счётчики обязательны (уточнение владельца): сколько дошло до
спасения, сколько спаслось, сколько ушло текстом целиком и почему.

Запуск: python3 tools/dictation_farm/rescue_measure.py  (llama-server :8080)
"""
import json
import os
import re
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))
os.chdir(os.path.join(HERE, "..", "semdict"))

import farm_text as FT                                   # noqa: E402
import run_farm as F                                     # noqa: E402
import pipeline as P                                     # noqa: E402
from farm_text import codec, negation_gate, final_gate, pre_detect  # noqa: E402

BY_EN = {e["en"]: c for c, e in codec.entries.items()}
BOUNDARIES = {BY_EN[n] for n in ("sent_end", "sent_question",
                                 "sent_exclaim") if n in BY_EN}


def split_sentences(text):
    out, cur = [], ""
    for ch in text:
        cur += ch
        if ch in ".?!…\n":
            t = cur.strip()
            if t:
                out.append(t)
            cur = ""
    t = cur.strip()
    if t:
        out.append(t)
    # Хвост без единой буквы — не предложение (#768, п.5 красной
    # сессии; зеркало Swift splitSentences — менять синхронно):
    # «)» после «?» становился «предложением», спасение отдавало его
    # вербатимом, а вопрос терялся. Приклеиваем к предыдущему.
    merged = []
    for s in out:
        if not re.search(r"[^\W\d_]", s) and merged:
            merged[-1] += s
        else:
            merged.append(s)
    return merged


def split_groups(units):
    groups, cur = [], []
    for u in units:
        cur.append(u)
        if u[0] == "code" and u[1] in BOUNDARIES:
            groups.append(cur)
            cur = []
    if cur:
        groups.append(cur)
    return groups


VERB_ADV_ADJ = ("ть", "чь", "ти", "о", "но", "ый", "ий", "ой", "ая",
                "ее", "ен")


def group_has_untraced_noun(units, source):
    src_words = re.findall(r"[^\W_]+", source.lower())

    def traced(ru):
        for w in re.findall(r"[^\W\d_]+", ru.lower()):
            if len(w) < 3:
                continue
            stem = w[:max(3, len(w) - 2)]
            if any(stem in sw for sw in src_words):
                return True
        return False

    for u in units:
        if u[0] != "code":
            continue
        ru = (codec.entries[u[1]].get("ru") or "").lower()
        if len(ru) < 3 or ru.endswith(VERB_ADV_ADJ):
            continue
        if not traced(ru):
            return True
    return False




# --- зеркала гейтов finish() 05.08 (менять синхронно с SemanticEncoder) ---

RU_DROPPABLE = {
    "если", "когда", "тогда", "здесь", "чтобы", "потому", "поэтому",
    "просто", "очень", "только", "ещё", "еще", "уже", "вообще",
    "конечно", "наверное", "может", "можно", "нужно", "надо",
    "есть", "нет", "этот", "эта", "это", "этом", "этим", "того",
    "тому", "всем", "всех", "чего", "кого", "какая", "какой",
    "которые", "который", "некоторые", "привет", "пожалуйста",
    "здравствуйте", "спасибо", "тебя", "тебе", "меня", "мной",
    "нему", "свои", "своими", "свой", "своя", "пока", "итак",
    "сейчас", "теперь", "разве", "вроде", "сами", "вашей", "ваша",
    "нельзя", "давайте", "буду", "будет", "будем", "могу", "хочу",
}
NON_NOUN_SUF = ("ть", "чь", "ти", "но", "ый", "ий", "ой", "ая", "яя",
                "ое", "ее", "ен", "ут", "ют", "ат", "ят", "ит", "ет",
                "ешь", "ишь", "те", "сь", "ся", "ла", "ло", "ли",
                "ые", "ие", "ду", "гу")

# Английские междометия и безапострофные формы (бриф 06.08 п.4):
# NUS-замер флаговал их «потерянными словами» — перефраз их законно
# теряет, существительными они не являются. Ряды ha/he/hm ловятся
# по составу букв (hahaha, hehehe, hmmm любой длины).
EN_DROPPABLE = {
    "haha", "hehe", "hiya", "heya", "alright", "okay", "okie", "yeah",
    "yeah", "yep", "yeps", "oops", "ohhh", "haiz", "sian", "walao",
    "aiyo", "aiya", "wahh", "huhu", "erm", "ermm", "hmm", "lolx",
    "lolz", "dont", "cant", "wont", "didnt", "doesnt", "isnt", "wasnt",
    "arent", "havent", "hasnt", "gonna", "wanna", "gotta", "kinda",
    "sorta", "thats", "whats", "youre", "theyre", "weve", "youve",
    "goodnight", "gudnite", "nite",
}
_EN_LAUGH_SETS = (set("ha"), set("he"), set("hm"), set("ho"))


def en_droppable(w):
    if w in EN_DROPPABLE:
        return True
    letters = set(w)
    return len(letters) <= 2 and any(letters <= s for s in _EN_LAUGH_SETS)
_TR = {"а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e",
       "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k",
       "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
       "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
       "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
       "э": "e", "ю": "yu", "я": "ya"}
NUM_WORDS = {"ноль": "0", "один": "1", "одна": "1", "одну": "1",
             "два": "2", "две": "2", "три": "3", "четыре": "4",
             "пять": "5", "шесть": "6", "семь": "7", "восемь": "8",
             "девять": "9", "десять": "10"}


def missing_noun_gate(source, units, rendered):
    """Гейт пропажи: существительное источника без следа в юнитах."""
    parts = [rendered.lower()]
    for u in units:
        if u[0] in ("lit", "name") and isinstance(u[1], str):
            parts.append(u[1].lower())
        elif u[0] == "code" and u[1] in codec.entries:
            e = codec.entries[u[1]]
            parts.append((e.get("ru") or "").lower())
            parts.append((e.get("en") or "").lower())
        elif u[0] == "num":
            parts.append(str(u[1]))
    hay = " ".join(parts).replace("ё", "е")
    for raw in re.findall(r"[^\W\d_]+", source.lower()):
        w = raw.replace("ё", "е")
        if len(w) < 4 or w in RU_DROPPABLE or en_droppable(w):
            continue
        if any(w.endswith(sf) for sf in NON_NOUN_SUF):
            continue
        if w[:4] in hay:
            continue
        t = "".join(_TR.get(c, c) for c in w)
        if len(t) >= 4 and t[:4] in hay:
            continue
        return f"потеряно слово «{raw}»"
    return None


def fabricated_numbers(source, rendered):
    """Цифры рендера, которых нет в источнике ни цифрой, ни словом."""
    allowed = set(re.findall(r"\d+", source))
    low = source.lower()
    for word, digit in NUM_WORDS.items():
        if word in low:
            allowed.add(digit)
    for n in re.findall(r"\d+", rendered):
        if n in allowed:
            continue
        if any(n in a or a in n for a in allowed):
            continue
        return f"число «{n}» не из источника"
    return None


def mixed_rescue(source, units):
    """→ (mixed_units, спасено, всего) | (None, причина)"""
    sents = split_sentences(source)
    if len(sents) < 2:
        return None, "одно предложение"
    groups = split_groups(units)
    if len(groups) != len(sents):
        return None, "выравнивание не 1:1"
    sent_end = ("code", BY_EN["sent_end"])
    mixed, rescued = [], 0
    for sent, group in zip(sents, groups):
        rendered = codec.render(group)
        fail = (negation_gate(sent, rendered)
                or group_has_untraced_noun(group, sent)
                or bool(final_gate(rendered, group)))
        if fail:
            mixed += [("lit", sent), sent_end]
            rescued += 1
        else:
            mixed += group
    if rescued == 0:
        return None, "гейты по предложениям прошли (провал не локализуем)"
    if rescued == len(sents):
        return None, "все предложения провалены"
    whole = codec.render(mixed)
    if negation_gate(source, whole) or group_has_untraced_noun(mixed, source):
        return None, "сборка не прошла гейты по целому"
    # паритет finish() 05.08: финальный гейт, пропажа, числа рендера
    if final_gate(whole, mixed):
        return None, "сборка: финальный гейт по целому"
    if missing_noun_gate(source, mixed, whole):
        return None, "сборка: пропажа по целому"
    if fabricated_numbers(source, whole):
        return None, "сборка: числа рендера"
    return (mixed, rescued, len(sents)), None


def encode_units(text):
    """Первый проход конвейера до гейтов: (units, причина-отказа-до-гейтов)."""
    pv, _ = F.pivot_for(text)
    if pv is None:
        return None, "пивот: отказ"
    sp = P.sanitize_pivot(pv, codec)
    units = P.units_from_pivot(sp, codec)
    if not units:
        return None, "матчер: пустые юниты"
    return (units, sp), None


def gate_reason(text, units, sp):
    if F.lost_numbers(text, sp):
        return "гейт чисел"
    lit = sum(len(u[1].encode()) for u in units if u[0] == "lit")
    blob = codec.encode(units)
    if blob and lit / len(blob) >= 0.5:
        return "литность >=50%"
    if final_gate(codec.render(units), units):
        return "финальный гейт"
    if negation_gate(text, codec.render(units)):
        return "гейт отрицаний"
    from entity_gate import untraced_entities
    ents_by_en = {e["en"].lower(): e.get("ru")
                  for e in codec.entries.values()}
    pairs = [(e["en"], e.get("ru")) for e in codec.entries.values()]
    if untraced_entities(text, sp, ents_by_en, pairs):
        return "гейт сущностей"
    return None


def corpus():
    out = []
    m = json.load(open(os.path.join(HERE, "out", "manifest.json")))
    seen = set()
    for c in m:
        if c["name"] not in seen:
            seen.add(c["name"])
            out.append(("полевая:" + c["name"], c["text"]))
    for line in open("dictation_corpus.jsonl"):
        d = json.loads(line)
        out.append(("диктовка", d["ru_dictation"]))
    out.append(("ночная-02.08", "иди к лодочной станции"))
    return out


def main():
    stats = dict(total=0, pregate=0, semantic_clean=0, reached=0,
                 rescued=0, full_text={}, pre_reasons={})
    saved_bytes = []
    rows = []
    for src, text in corpus():
        stats["total"] += 1
        if pre_detect(text):
            stats["pregate"] += 1
            continue
        enc, why = encode_units(text)
        if enc is None:
            stats["pre_reasons"][why] = stats["pre_reasons"].get(why, 0) + 1
            continue
        units, sp = enc
        reason = gate_reason(text, units, sp)
        if reason is None:
            stats["semantic_clean"] += 1
            continue
        # провал гейта — кандидат на спасение
        stats["reached"] += 1
        rescue, fail_why = mixed_rescue(text, units)
        text_bytes = 1 + len(zlib.compress(text.encode(), 9))
        if rescue is None:
            stats["full_text"][fail_why] = stats["full_text"].get(fail_why,
                                                                  0) + 1
            rows.append((src, reason, "текст целиком: " + fail_why,
                         text_bytes, "—"))
        else:
            mixed, r, n = rescue
            b = len(codec.wire_blob(codec.encode(mixed)))
            stats["rescued"] += 1
            saved_bytes.append((text_bytes, b))
            rows.append((src, reason, f"спасено {r}/{n} предл. вербатимом",
                         text_bytes, b))

    print("## Прогон фермы с сегментным спасением\n")
    print(f"Сообщений: {stats['total']} (полевые 15, диктовки 10, "
          "ночная 1; остальные 11 ночных текстов в git не сохранены —"
          " агрегаты только в отчёте 02.08)\n")
    print(f"- пре-гейт (короткое/лексикон): {stats['pregate']}")
    print(f"- отказ до гейтов: {stats['pre_reasons']}")
    print(f"- смыслом без спасения: {stats['semantic_clean']}")
    print(f"- дошло до сегментного спасения: {stats['reached']}")
    print(f"- спасено (смешанный режим): {stats['rescued']}")
    print(f"- текст целиком, по причинам: {stats['full_text']}\n")
    if rows:
        print("| Корпус | Провал | Исход | Текст, Б | Смешанный, Б |")
        print("|---|---|---|---|---|")
        for r in rows:
            print("| " + " | ".join(str(x) for x in r) + " |")
    if saved_bytes:
        t = sum(a for a, _ in saved_bytes)
        m = sum(b for _, b in saved_bytes)
        print(f"\nРазница получена на {len(saved_bytes)} сообщениях: "
              f"текстом {t} Б → смешанным {m} Б.")
    else:
        print("\nСпасённых нет — дельты размеров нет ни на одном "
              "сообщении (честно ноль).")


if __name__ == "__main__":
    main()
