# -*- coding: utf-8 -*-
"""Сборка ядра словаря R+M v0.

Источники:
  - concepticon.tsv  (концепт-сеты: стабильный ID смысла + определение)
  - en_50k.txt       (частоты OpenSubtitles-2018, разговорный регистр)
  - curated_data.py  (защищённый слой, грамматика, обороты, RU-строки)

Выход: rm_dict_core_v0.json
  - каждому смыслу: code (навсегда), слой, en, ru, определение/привязка к
    Concepticon, частота, длина канонического кода Хаффмана в битах.
"""
import csv, json, heapq, re
from collections import defaultdict
from curated_data import PROTECTED, GRAMMAR, PHRASES, RU_SINGLES, DOMAIN_SINGLES, CHAT_SINGLES, CHAT_PHRASES, WEEKDAYS_MONTHS, EXPANSION_SINGLES, EXPANSION_PHRASES

# ------------------------------------------------------------------ частоты
freq = {}
with open("en_50k.txt", encoding="utf-8") as f:
    for line in f:
        w, c = line.split()
        freq[w] = int(c)

# ------------------------------------------------------------------ Concepticon
# Берём одиночные глоссы, живущие в верхе разговорного частотника.
concepticon = {}          # gloss_lower -> (id, definition, pos_hint)
with open("concepticon.tsv", encoding="utf-8") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        if row.get("REPLACEMENT_ID"):          # устаревшие сеты пропускаем
            continue
        gloss = row["GLOSS"].strip().lower()
        # одиночные слова; составные глоссы Concepticon ("go up") пока мимо —
        # многословность у нас закрывают кураторские PHRASES
        if not re.fullmatch(r"[a-z]+", gloss):
            continue
        # при дублях глосс оставляем первый (самый общий) сет
        if gloss not in concepticon:
            concepticon[gloss] = (row["ID"], row["DEFINITION"].strip(),
                                  row["ONTOLOGICAL_CATEGORY"].strip())

FREQ_CUTOFF_RANK = 8000    # кандидат должен жить в топ-8000 разговорной речи
ranked = {w: i + 1 for i, (w, _) in enumerate(
    sorted(freq.items(), key=lambda kv: -kv[1]))}

singles = []               # (gloss, freq, concepticon_id, definition, cat)
for gloss, (cid, definition, cat) in concepticon.items():
    r = ranked.get(gloss)
    if r and r <= FREQ_CUTOFF_RANK:
        singles.append((gloss, freq[gloss], cid, definition, cat))
singles.sort(key=lambda t: -t[1])

# Служебные и сверхчастые слова, которых нет в Concepticon (местоимения,
# предлоги, союзы, бытовые пропуски) — добираем из частотника напрямую.
# Это "RM-собственные" смыслы без привязки к Concepticon.
concept_words = {s[0] for s in singles}
EXTRA_TOP_RANK = 700       # всё из топ-700 разговорной речи обязано быть в словаре
STOP_JUNK = {"s", "t", "m", "re", "ve", "ll", "d", "em", "y", "gonna", "gotta",
             "don", "didn", "doesn", "wasn", "isn", "wouldn", "couldn", "haven",
             "aren", "ain", "won", "weren", "hasn", "hadn", "shouldn", "mustn",
             "wanna", "ya", "uh", "um", "oh", "ah", "hey", "huh", "hm", "mm",
             "na", "la", "da", "ha"}
extras = []
for w, r in ranked.items():
    if r <= EXTRA_TOP_RANK and w not in concept_words and w not in STOP_JUNK \
            and re.fullmatch(r"[a-z]+", w):
        extras.append((w, freq[w]))
extras.sort(key=lambda t: -t[1])

TARGET_SINGLES = 780       # одиночных смыслов в ядре v0
merged_singles = []
seen = set()
for gloss, fc, cid, definition, cat in singles:
    if len(merged_singles) >= TARGET_SINGLES: break
    merged_singles.append(dict(en=gloss, freq=fc, concepticon_id=cid,
                               definition=definition, category=cat))
    seen.add(gloss)
for w, fc in extras:
    pass  # весь топ-700 без капа: базовая речь обязана быть в ядре
    if w in seen: continue
    merged_singles.append(dict(en=w, freq=fc, concepticon_id=None,
                               definition=None, category="Function/Other"))
    seen.add(w)

# ------------------------------------------------------------------ сборка слоёв
entries = []

def add(layer, code, en, ru, fc, cid=None, definition=None, category=None):
    entries.append(dict(code=code, layer=layer, en=en, ru=ru, freq=fc,
                        concepticon_id=cid, definition=definition,
                        category=category))

# защищённый слой: 0x0000-0x00FF
for i, (en, ru, fc) in enumerate(PROTECTED):
    assert i <= 0xFF
    add("protected", 0x0000 + i, en, ru, fc)

# грамматика: 0x0100-0x011F (частота условная, в замере v0 не участвуют)
for i, (en, ru) in enumerate(GRAMMAR):
    assert i <= 0x1F
    add("grammar", 0x0100 + i, en, ru, 100000)

# Границы предложений (v1.1, 29.07): одни из самых частых кодов —
# заведены ДО заморозки v1.1, чтобы Хаффман дал короткие биты
# (append-only после заморозки дал бы 16-20 бит навсегда). Частоты —
# оценка по корпусу: ~1.2 точки на сообщение (уровень топ-слов),
# вопрос в ~4 раза реже, восклицание в ~10.
# Шкала частотника — абсолютные счётчики OpenSubtitles (топ ~28M).
# Точка — примерно каждый десятый токен (одна на предложение из 8-12
# слов) — уровень топ-1; вопрос ~в 5 раз реже, восклицание ~в 15.
BOUNDARIES = [("sent_end", ".", 25_000_000),
              ("sent_question", "?", 5_000_000),
              ("sent_exclaim", "!", 1_600_000)]
for j, (en, ru, fc) in enumerate(BOUNDARIES):
    assert len(GRAMMAR) + j <= 0x1F
    add("grammar", 0x0100 + len(GRAMMAR) + j, en, ru, fc)

# свободный слой: 0x0120+ ; сначала обороты, затем одиночки — по убыванию частоты
free = []
for en, ru, fc in PHRASES:
    free.append(dict(en=en, ru=ru, freq=fc, concepticon_id=None,
                     definition=None, category="Phrase"))
domain_seen = set()
for en, ru, fc in CHAT_SINGLES + CHAT_PHRASES + WEEKDAYS_MONTHS + EXPANSION_SINGLES + EXPANSION_PHRASES:
    domain_seen.add(en)
    free.append(dict(en=en, ru=ru, freq=fc, concepticon_id=None,
                     definition=None, category="Chat"))
for en, ru, fc in DOMAIN_SINGLES:
    domain_seen.add(en)
    free.append(dict(en=en, ru=ru, freq=fc, concepticon_id=None,
                     definition=None, category="Domain"))
for s in merged_singles:
    if s["en"] in domain_seen:
        continue
    s["ru"] = RU_SINGLES.get(s["en"])
    free.append(s)
# дедупликация по en: при совпадении имён побеждает запись с RU и большей частотой
best = {}
for d in free:
    k = d["en"]
    if k not in best or (bool(d.get("ru")), d["freq"]) > (bool(best[k].get("ru")), best[k]["freq"]):
        best[k] = d
free = list(best.values())
free.sort(key=lambda d: -d["freq"])

# ------------------------------------------------------------- append-only
# Шапка этого файла обещает «code (навсегда)», но назначение по порядку
# убывания частоты нарушало обещание: вставка новых слов сдвигала все
# последующие коды, и 890 смыслов менялись местами (поймано 03.08 при
# дополнении словаря). Теперь код смысла берётся из ПРЕДЫДУЩЕЙ версии,
# а новички получают коды в хвосте. Длины в битах при этом меняются —
# это неизбежно при пересборке Хаффмана и ловится байтом отпечатка.
import os as _os
_prev_codes = {}
if _os.path.exists("rm_dict_core_v0.json"):
    _prev = json.load(open("rm_dict_core_v0.json", encoding="utf-8"))
    _prev_codes = {e["en"]: e["code"] for e in _prev["entries"]
                   if e["layer"] == "free"}
_next_free = max(_prev_codes.values(), default=0x0120 - 1) + 1
for d in free:
    _code = _prev_codes.get(d["en"])
    if _code is None:
        _code = _next_free
        _next_free += 1
    add("free", _code, d["en"], d.get("ru"), d["freq"],
        d.get("concepticon_id"), d.get("definition"), d.get("category"))
entries.sort(key=lambda e: e["code"])

# escape-коды: 0xF000+
ESCAPES = [
    ("esc_number",  "число (varint 1-3 байта)"),
    ("esc_coords",  "координаты (8 байт, как в SOS)"),
    ("esc_time",    "время (varint: минуты суток 0-1439 или unix-минуты)"),
    ("esc_literal", "текст как есть (len + utf8/zstd)"),
    ("esc_name",    "имя собственное (len + utf8)"),
    ("esc_local",   "переключение на локальный словарь группы"),
    ("esc_amount",  "сумма денег (1 байт валюты ISO-субсета + varint)"),
    ("esc_extension", "расширение: 12 бит индекса (4096 будущих кодов)"),
]
for i, (en, ru) in enumerate(ESCAPES):
    add("escape", 0xF000 + i, en, ru, 200000)

# ------------------------------------------------------------------ Хаффман
# Канонический Хаффман по частотам -> длины кодов в битах. Таблица длин
# детерминирована и версионируется вместе со словарём. Грамматика и escape
# участвуют в дереве (они летят в том же потоке).
def huffman_lengths(items):
    """items: list[(key, freq)] -> dict key->bits (канонический Хаффман)."""
    heap = [(f, i, [k]) for i, (k, f) in enumerate(items)]
    heapq.heapify(heap)
    depth = defaultdict(int)
    nxt = len(heap)
    if len(heap) == 1:
        return {heap[0][2][0]: 1}
    while len(heap) > 1:
        f1, _, k1 = heapq.heappop(heap)
        f2, _, k2 = heapq.heappop(heap)
        for k in k1 + k2:
            depth[k] += 1
        heapq.heappush(heap, (f1 + f2, nxt, k1 + k2)); nxt += 1
    return dict(depth)

lengths = huffman_lengths([(e["code"], e["freq"]) for e in entries])
for e in entries:
    e["bits"] = lengths[e["code"]]

# ------------------------------------------------------------------ выпуск
dictionary = {
    "format": "rm-dict",
    # 1.3.0 (03.08.2026): дополнение по замеру живого трафика —
    # 25 записей обиходной координации в формах владельческой речи
    # (docs/reports/dict_coverage_2026-08-03.md). Пересборка меняет
    # отпечаток и длины кодов; узлы со старым словарём увидят
    # расхождение версий и честно откатятся (VersionSkewTests).
    "version": "1.3.0",
    "pivot": "en",
    "rules": [
        "ЗАМОРОЖЕН 28.07.2026 (v1): пересборок нет, свободный слой append-only.",
        "Код никогда не меняет значение; новые смыслы получают новые коды.",
        "Словарь растёт только вперёд; переопределение запрещено.",
        "Несовпадение отпечатка таблицы у получателя -> текстовая заглушка, блоб хранится до обновления.",
        "Таблица длин Хаффмана канонична и фиксируется версией словаря.",
        "SOS-режим: только слои protected/escape + подтверждение человеком.",
    ],
    "ranges": {
        "protected": "0x0000-0x00FF",
        "grammar":   "0x0100-0x011F",
        "free":      "0x0120-0x7FFF",
        "local":     "0x8000-0xBFFF (словарь группы, синхронизируется отдельно)",
        "escape":    "0xF000-0xF00F",
    },
    "stats": {},
    "entries": entries,
}

n_by_layer = defaultdict(int)
for e in entries: n_by_layer[e["layer"]] += 1
wsum = sum(e["freq"] * e["bits"] for e in entries)
fsum = sum(e["freq"] for e in entries)
dictionary["stats"] = {
    "entries_total": len(entries),
    "by_layer": dict(n_by_layer),
    "avg_bits_weighted": round(wsum / fsum, 2),
    "bits_min": min(e["bits"] for e in entries),
    "bits_max": max(e["bits"] for e in entries),
    "ru_coverage": round(sum(1 for e in entries if e["ru"]) / len(entries), 3),
}

# ------------------------------------------------------------------ замок v1
# Словарь ЗАМОРОЖЕН: существующий файл версии >= 1.0.0 разрешает
# только чистое добавление в хвост (все старые коды сохраняют смысл
# И длину бита). Любое другое расхождение — отказ от записи.
import os
if os.path.exists("rm_dict_core_v0.json"):
    old = json.load(open("rm_dict_core_v0.json", encoding="utf-8"))
    rebuild_target = os.environ.get("RM_DICT_REBUILD")
    if rebuild_target and rebuild_target == dictionary["version"]:
        print(f"ПЕРЕСБОРКА САНКЦИОНИРОВАНА: {old['version']} -> "
              f"{rebuild_target} (RM_DICT_REBUILD)")
    elif not old["version"].endswith("-draft"):
        old_map = {e["code"]: (e["en"], e["bits"]) for e in old["entries"]}
        new_map = {e["code"]: (e["en"], e["bits"]) for e in entries}
        broken = [c for c, v in old_map.items() if new_map.get(c) != v]
        if broken:
            raise SystemExit(
                f"СЛОВАРЬ ЗАМОРОЖЕН (v{old['version']}): "
                f"{len(broken)} существующих кодов изменили смысл или "
                f"длину (первые: {broken[:5]}). Append-only, пересборок нет.")

with open("rm_dict_core_v0.json", "w", encoding="utf-8") as f:
    json.dump(dictionary, f, ensure_ascii=False, indent=1)

print(json.dumps(dictionary["stats"], ensure_ascii=False, indent=2))
print("примеры длин (частое -> редкое):")
for e in sorted(entries, key=lambda e: -e["freq"])[:8]:
    print(f"  {e['bits']:>2} бит  {e['en']}")
for e in sorted(entries, key=lambda e: e["freq"])[:4]:
    print(f"  {e['bits']:>2} бит  {e['en']}")
