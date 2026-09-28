# -*- coding: utf-8 -*-
"""Детерминированный экстрактор фактов (ферма, п.2).

Категории: numbers · time · names · negations · places · entities.
Первые пять — из брифа; entities (предметные content-слова) добавлена,
потому что ручная разметка chat-корпуса содержит факты вне пяти
категорий (генератор, свет, «слышит»…) — без неё валидация «те же 36»
невыполнима.

Работает по русскому входу/рендеру И по английскому пивот-входу
(текстовый контур): канон сущности — русский стем словарной статьи,
если слово словарное; иначе сырой стем. Сверка фактов «вход ↔ рендер
приёмника» — по пересечению канонов в каждой категории.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))

_DICT = json.load(open(os.path.join(HERE, "..", "semdict",
                                    "rm_dict_core_v0.json"), encoding="utf-8"))
# en-слово -> ru-строка (первый слэш-вариант, первое слово)
EN2RU = {}
for _e in _DICT["entries"]:
    if _e.get("ru"):
        first = _e["ru"].split()[0].split("/")[0].lower()
        EN2RU[_e["en"]] = first

NUM_WORDS = {
    "ноль": 0, "один": 1, "одна": 1, "одну": 1, "два": 2, "две": 2,
    "двух": 2, "три": 3, "трёх": 3, "трех": 3, "четыре": 4, "четырёх": 4,
    "пять": 5, "пяти": 5, "шесть": 6, "шести": 6, "семь": 7, "семи": 7,
    "восемь": 8, "восьми": 8, "девять": 9, "девяти": 9, "десять": 10,
    "десяти": 10, "одиннадцать": 11, "двенадцать": 12, "пятнадцать": 15,
    "двадцать": 20, "двадцати": 20, "тридцать": 30, "тридцати": 30,
    "сорок": 40, "пятьдесят": 50, "шестьдесят": 60, "семьдесят": 70,
    "восемьдесят": 80, "девяносто": 90, "сто": 100, "двести": 200,
    "триста": 300, "пятьсот": 500, "тысяча": 1000, "тысячу": 1000,
    # английские (текстовый контур)
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
    "fifty": 50, "hundred": 100, "thousand": 1000,
}
TENS = {20, 30, 40, 50, 60, 70, 80, 90}

DAYS = {"понедельник": "пн", "вторник": "вт", "сред": "ср", "четверг": "чт",
        "пятниц": "пт", "суббот": "сб", "воскресень": "вс",
        "monday": "пн", "tuesday": "вт", "wednesday": "ср",
        "thursday": "чт", "friday": "пт", "saturday": "сб", "sunday": "вс"}
RELDAYS = {"сегодня": "today", "завтра": "tomorrow",
           "послезавтра": "aftertomorrow", "вчера": "yesterday",
           "today": "today", "tomorrow": "tomorrow", "yesterday": "yesterday"}
DAYPARTS = {"утр": "morning", "вечер": "evening", "ноч": "night",
            "полдень": "noon", "morning": "morning", "evening": "evening",
            "night": "night", "noon": "noon", "tonight": "evening"}

NEG_MARKERS_CANCEL = {"отбой", "отмена", "отменяется", "отменяем", "отменить",
                      "cancel", "cancelled", "canceled"}
NEG_TOKENS = {"не", "нет", "нельзя", "not", "no", "don't", "doesn't",
              "didn't", "won't", "can't", "cannot", "never"}

PLACES = {
    # ru-стемы
    "мост", "кафе", "рынок", "рынк", "дом", "дома", "пляж", "дорог",
    "гора", "горах", "лес", "деревн", "город", "заправ", "пирс", "берег",
    "школ", "магазин", "аптек", "больниц", "банк", "банкомат", "останов",
    "вокзал", "аэропорт", "площад", "парк", "рек", "озер", "мор", "остров",
    "пристан", "храм", "церк", "клиник", "офис", "гостиниц", "отел",
    # направления
    "север", "юг", "юж", "восток", "восточ", "запад", "налево", "направо",
    "прямо", "наверх", "вниз", "внизу", "выезд", "въезд",
    # английские (маппятся в ru через EN2RU при канонизации,这 запас)
    "bridge", "cafe", "market", "home", "beach", "road", "mountain",
    "forest", "village", "town", "city", "pier", "shore", "school",
    "shop", "store", "pharmacy", "hospital", "bank", "station", "airport",
    "square", "park", "river", "lake", "sea", "island", "north", "south",
    "east", "west", "left", "right", "upstairs", "downstairs",
}

STOP_RU = {"это", "этот", "если", "чтобы", "когда", "потом", "потому",
           "просто", "очень", "тоже", "либо", "хотя", "пока", "надо",
           "нужно", "может", "быть", "есть", "буду", "будет", "будем",
           "меня", "тебя", "него", "неё", "нами", "вами", "себя", "который",
           "которая", "все", "всё", "всех", "там", "тут", "здесь", "туда",
           "сюда", "где", "куда", "как", "так", "что", "кто", "они", "оно",
           "она", "мой", "твой", "наш", "ваш", "свой", "сам", "сама",
           "теб", "вас", "нас"}
STOP_EN = {"the", "and", "that", "this", "with", "will", "would", "have",
           "has", "had", "are", "was", "were", "you", "your", "they",
           "them", "their", "she", "him", "her", "his", "its", "our",
           "for", "from", "about", "just", "very", "really", "then",
           "than", "but", "not", "all", "can", "could", "should", "there",
           "here", "what", "when", "where", "who", "how", "why", "yes"}

TOKEN = re.compile(r"\d{1,2}:\d{2}|[a-zа-яё']+|\d+|%", re.I)

# Синонимные каноны: устойчивые смыслы, которые буквальный стем не
# ловит («телефон садится» = батарея). Детерминированная таблица.
SYNONYM_CANONS = {
    "сади": ["бата"],       # телефон/батарея садится
    "разряж": ["бата"],
    "dying": ["бата"], "died": ["бата"],
}
# биграммы-места («там же где вчера» — место встречи)
PLACE_BIGRAMS = {("там", "же"): "там же",
                 ("того", "же"): "там же",   # «у того же где вчера»
                 ("same", "place"): "там же"}


def _stem(w):
    """Грубый стем: 4 буквы для кириллицы, лемма-словарь для латиницы."""
    if re.match(r"[a-z]", w):
        ru = EN2RU.get(w) or EN2RU.get(w.rstrip("s"))
        if ru:
            return ru[:4]
        return "en:" + w[:5]
    return w[:4]


def extract(text):
    """text -> dict категория -> set канонов."""
    facts = {"numbers": set(), "time": set(), "names": set(),
             "negations": set(), "places": set(), "entities": set()}
    raw_tokens = TOKEN.findall(text)
    tokens = [t.lower() for t in raw_tokens]

    # имена: заглавная не в начале предложения + NAME:-маркеры
    sentence_start = True
    for m in re.finditer(r"[A-ZА-ЯЁ]?[a-zа-яё']+|[A-ZА-ЯЁ][A-Za-zА-Яа-яё']*|\S",
                         text):
        w = m.group(0)
        if not re.match(r"[A-Za-zА-Яа-яЁё]", w):
            sentence_start = sentence_start or bool(re.search(r"[.!?…]", w))
            continue
        if (w[0].isupper() and not sentence_start and len(w) >= 3
                and w.lower() not in NUM_WORDS):
            facts["names"].add(w.lower()[:6])
        sentence_start = bool(re.search(r"[.!?…]\s*$",
                                        text[:m.end() + 1][-2:]))
    for m in re.finditer(r"name[:_]([a-zа-яё]+)", text, re.I):
        facts["names"].add(m.group(1).lower()[:6])

    i = 0
    while i < len(tokens):
        t = tokens[i]
        nxt = tokens[i + 1] if i + 1 < len(tokens) else ""

        if ":" in t:                                   # HH:MM
            h, m = map(int, t.split(":"))
            facts["time"].add(("clock", h * 60 + m))
            facts["numbers"].add(h if m == 0 else h * 60 + m)
            i += 1
            continue
        if t.isdigit():
            n = int(t)
            facts["numbers"].add(n)
            # am/pm сдвигают часы; русский рендер пишет «N после полудня
            # (pm)» / «N до полудня (am)» — читаем оба вида
            meridiem = None
            if nxt in ("am", "pm"):
                meridiem = nxt
            elif nxt in ("после", "до") and i + 2 < len(tokens) \
                    and tokens[i + 2].startswith("полудн"):
                meridiem = "pm" if nxt == "после" else "am"
            if meridiem or (len(t) in (3, 4) and t[0] == "0"
                            and n % 100 < 60):
                hh = n if n <= 23 else n // 100
                mm = 0 if n <= 23 else n % 100
                if meridiem:
                    hh = hh % 12 + (12 if meridiem == "pm" else 0)
                facts["time"].add(("clock", (hh % 24) * 60 + mm))
            i += 1
            continue
        if t in NUM_WORDS:                              # числительные словами
            n = NUM_WORDS[t]
            if n in TENS and nxt in NUM_WORDS and NUM_WORDS[nxt] < 10:
                n += NUM_WORDS[nxt]
                i += 1
            facts["numbers"].add(n)
            i += 1
            continue

        if t in NEG_MARKERS_CANCEL:
            facts["negations"].add(("cancel",))
        elif t in NEG_TOKENS:
            # отрицаемое слово: следующее содержательное (для «нет» —
            # предыдущее: «бензина нет»)
            target = nxt
            if t in ("нет", "no") and i > 0 and len(tokens[i - 1]) >= 3:
                target = tokens[i - 1]
            if target and len(target) >= 2 and target not in NEG_TOKENS:
                facts["negations"].add(("neg", _stem(target)))

        low = t
        for stem, canon in DAYS.items():
            if low.startswith(stem):
                facts["time"].add(("day", canon))
        if low in RELDAYS:
            facts["time"].add(("relday", RELDAYS[low]))
        for stem, canon in DAYPARTS.items():
            if low.startswith(stem):
                facts["time"].add(("part", canon))

        if any(low.startswith(p) for p in PLACES):
            facts["places"].add(_stem(low))
        if (low, nxt) in PLACE_BIGRAMS:
            facts["places"].add(PLACE_BIGRAMS[(low, nxt)])
        for syn_stem, canons in SYNONYM_CANONS.items():
            if low.startswith(syn_stem):
                facts["entities"].update(canons)

        # сущности: содержательные слова len>=4 вне стоп-листов
        if (len(low) >= 4 and low not in STOP_RU and low not in STOP_EN
                and low not in NUM_WORDS and not low.isdigit()):
            facts["entities"].add(_stem(low))
        i += 1
    return facts


_TRANSLIT = {"а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e",
             "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "i", "к": "k",
             "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
             "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts",
             "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
             "э": "e", "ю": "yu", "я": "ya"}
_RU_PREFIXES = ("по", "под", "при", "за", "вы", "от", "пере",
                "до", "на", "об", "с", "у")


def _translit(w):
    return "".join(_TRANSLIT.get(c, c) for c in w)


def _strip_prefix(w):
    for p in _RU_PREFIXES:
        if w.startswith(p) and len(w) - len(p) >= 2:
            return w[len(p):]
    return w


def _soft_eq(a, b):
    """Мягкое стем-сравнение: общий префикс 3 (морфология окончаний)."""
    return a[:3] == b[:3] and len(a) >= 3


def delivered(source_facts, render_facts):
    """Поэлементная сверка: (категория, факт, доставлен?).

    Сверка мягче извлечения: транслит для имён (Тома ↔ Tom), срез
    русских приставок для отрицаний (не подумал ↔ не думать), общий
    префикс-3 для сущностей (ясный ↔ ясно). Категории не смешиваются.
    """
    out = []
    for cat, items in source_facts.items():
        for f in items:
            ok = f in render_facts[cat]
            if not ok and cat == "names":
                src = _translit(str(f))
                ok = any(_soft_eq(src, _translit(str(r)))
                         for r in render_facts["names"])
            if not ok and cat == "negations" and f[0] == "neg":
                base = _strip_prefix(str(f[1]))
                ok = any(r[0] == "neg"
                         and base[:2] == _strip_prefix(str(r[1]))[:2]
                         for r in render_facts["negations"]
                         if isinstance(r, tuple) and len(r) == 2)
            if not ok and cat in ("entities", "places"):
                ok = any(_soft_eq(str(f), str(r))
                         for r in render_facts[cat])
            # число могло уехать в time (07:20 -> clock 440) — не потеря
            if not ok and cat == "numbers":
                for entry in render_facts["time"]:
                    if entry[0] == "clock":
                        v = entry[1]
                        if f in (v, v // 60, v % 60, (v // 60) * 100 + v % 60):
                            ok = True
                            break
            out.append((cat, f, ok))
    return out


def classify_loss(fact, cat, rendered_text):
    """Потерянный факт: 'artifact' (шум сверки: синонимия/морфология/
    транслит — след смысла в рендере есть при супермягком сравнении)
    или 'real' (следа нет — реальное выпадение смысла)."""
    probes = []
    if cat == "numbers":
        probes.append(str(fact))
    elif isinstance(fact, tuple):
        probes += [str(p) for p in fact if isinstance(p, str)]
    else:
        probes.append(str(fact))
    tokens = [t.lower() for t in re.findall(r"[a-zа-яё]+", rendered_text,
                                            re.I)]
    for probe in probes:
        p = _strip_prefix(probe.lower().replace("en:", ""))
        variants = {p[:2], _translit(p)[:3]}
        for tok in tokens:
            t2 = _strip_prefix(tok)
            if any(v and (t2.startswith(v) or _translit(t2).startswith(v))
                   for v in variants):
                return "artifact"
    return "real"


if __name__ == "__main__":
    demo = "Слушай, отбой по старому кафе, туда не идём. Возьми 200 дирхамов."
    for cat, items in extract(demo).items():
        if items:
            print(cat, "->", items)
