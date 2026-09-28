# -*- coding: utf-8 -*-
"""Гейт выдуманных сущностей — python-порт SemanticEncoder (31.07).

Обязан давать тот же вердикт, что Swift untracedEntities: словарное
en-слово трассируется ru-стемами записи до входа; NAME: и внесловарные
длинные слова — транслит-префиксом. Служебные слова не гейтятся.
"""
import re

FUNCTION_WORDS = {
    "a", "an", "the", "i", "you", "we", "they", "he", "she", "it",
    "me", "us", "them", "my", "your", "our", "his", "her", "their",
    "this", "that", "these", "those", "there", "here",
    "is", "are", "am", "was", "were", "be", "been", "being",
    "do", "does", "did", "not", "no", "yes", "and", "or", "but",
    "if", "so", "to", "of", "in", "on", "at", "by", "for", "with",
    "from", "as", "than", "then", "now", "soon", "very", "too",
    "will", "would", "can", "could", "should", "must", "may",
    "have", "has", "had", "get", "got", "go", "going", "come",
    "please", "ok", "okay", "about", "up", "down", "out", "back",
    "all", "everything", "something", "nothing", "one", "some",
    "more", "only", "just", "still", "already", "again",
}

# Сокращения → полные формы (очередь владельца 06.08, промер NUS:
# because ×26 ← cos/cuz, tomorrow ×17 ← tmr/tml, people ×11 ← ppl).
# ТОЛЬКО трассировка гейта — словарь кодека не трогается.
EN_ABBREV = {
    "cos": ("because",), "cuz": ("because",), "coz": ("because",),
    "bcos": ("because",), "bcoz": ("because",),
    "tmr": ("tomorrow",), "tml": ("tomorrow",), "tmrw": ("tomorrow",),
    "ppl": ("people",), "pple": ("people",),
    "u": ("you",), "ur": ("your",), "pls": ("please",), "plz": ("please",),
    "msg": ("message",), "msgs": ("messages",),
    "min": ("minute",), "mins": ("minutes",),
    "mon": ("monday",), "tue": ("tuesday",), "wed": ("wednesday",),
    "thu": ("thursday",), "fri": ("friday",), "sat": ("saturday",),
    "sun": ("sunday",),
    "wat": ("what",), "wen": ("when",), "den": ("then",),
    "dun": ("dont",), "dunno": ("dont", "know"), "knw": ("know",),
    "nt": ("not",), "abt": ("about",), "thx": ("thanks",),
    "ty": ("thanks",), "gd": ("good",), "nite": ("night",),
    "oredi": ("already",), "alr": ("already",), "shld": ("should",),
    "cld": ("could",), "wld": ("would",), "hv": ("have",), "gt": ("got",),
    "aft": ("after",), "b4": ("before",), "l8r": ("later",),
    "sch": ("school",), "ya": ("yes", "yep"), "yah": ("yes", "yep"),
    "yeah": ("yep",), "frnd": ("friend",), "frnds": ("friends", "friend"),
}

TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e",
    "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k",
    "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
    "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts",
    "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "",
    "э": "e", "ю": "yu", "я": "ya",
}


def translit(word):
    return "".join(TRANSLIT.get(ch, ch) for ch in word.lower())


def untraced_entities(source, pivot, entries_by_en, entries=None):
    """entries_by_en: en-слово (lower) -> ru-строка (или None);
    entries: [(en, ru)] всех записей — для лицензирования слов
    многословных en-фраз, чей ru сводится к входу (класс (б):
    «послезавтра» лицензирует day/after/tomorrow)."""
    source_words = re.findall(r"[^\W_]+", source.lower())
    # Английская трассировка (06.08): апострофы (don't → dont; сплит
    # [^\W_]+ рвал их на don+t), склейки соседних слов (may be →
    # maybe), развёрнутые сокращения (tmr → tomorrow) — добавляются к
    # словам источника ТОЛЬКО для трассировки, словарь не трогается.
    trace_words = list(source_words)
    trace_words += [w.replace("'", "") for w in
                    re.findall(r"[^\W\d_]+(?:'[^\W\d_]+)+", source.lower())]
    trace_words += [a + b for a, b in zip(source_words, source_words[1:])]
    for w in source_words:
        trace_words += EN_ABBREV.get(w, ())
    source_translit = [translit(w) for w in trace_words]
    source_exact = {w.replace("ё", "е") for w in source_words}

    def traced_by_stem(ru_text):
        for ru_word in re.findall(r"[а-яё]+", (ru_text or "").lower()):
            if len(ru_word) < 4:
                # Лечение 05.08 (live_corpus §5): короткие ru-слова
                # («как», «где», «раз») не имеют стема ≥4 — сверка
                # ЦЕЛЫМ словом, е/ё нормализованы. Подстрока не
                # считается: «карта» не лицензирует «как».
                if ru_word.replace("ё", "е") in source_exact:
                    return True
                continue
            stem = ru_word[:max(4, len(ru_word) - 2)]
            if any(stem in w for w in source_words):
                return True
        return False

    def traced_by_translit(latin):
        needle = latin.lower()[:4]
        if len(needle) < 3:
            return True
        if any(t.startswith(needle) for t in source_translit):
            return True
        # Словоформы (06.08): пивот-слово начинается со слова источника
        # и длиннее его не более чем на 3 (say→says, ask→asked,
        # come→coming). КОРОТКИЕ служебные (≤3 букв: the, are, was) не
        # лицензируют — класс «the ↛ theory» (замок); длинные (come,
        # going) лицензируют свои формы законно.
        word = latin.lower()
        for t in source_translit:
            if len(t) < 3 or (len(t) <= 3 and t in FUNCTION_WORDS):
                continue
            # немая e роняется в формах: come→coming, make→making
            stems = (t, t[:-1]) if t.endswith("e") and len(t) >= 4 else (t,)
            if any(word.startswith(s) and len(word) - len(s) <= 3
                   for s in stems):
                return True
        return False

    licensed = set()
    for en, ru in (entries or []):
        if en and ru and " " in en and traced_by_stem(ru):
            for w in re.findall(r"[a-z]+", en.lower()):
                licensed.add(w)

    def ru_looks_like_noun(ru):
        m = re.findall(r"[а-яё]+", (ru or "").lower())
        if not m:
            return False
        w = m[0]
        for suf in ("ться", "ть", "чь", "ти", "но", "о", "ый", "ий",
                    "ой", "ая", "яя", "ое", "ее", "ен"):
            if w.endswith(suf):
                return False
        return True

    def dict_ru(word):
        if word in entries_by_en:
            return True, entries_by_en[word]
        if word.endswith("es") and word[:-2] in entries_by_en:
            return True, entries_by_en[word[:-2]]
        if word.endswith("s") and word[:-1] in entries_by_en:
            return True, entries_by_en[word[:-1]]
        return False, None

    bad = []           # плоский список (контракт гейта)
    kinds = []         # (токен, вид): name | noun | offlex — для метрик
    for token in pivot.split():
        low = token.lower()
        if low.startswith("name:") or low.startswith("name_"):
            name = re.split(r"[:_]", token, 1)[1]
            if not traced_by_translit(name):
                bad.append(token)
                kinds.append((token, "name"))
            continue
        word = low.strip('.,!?;()"')
        if len(word) < 3 or not word.isalpha() or word in FUNCTION_WORDS \
           or word in licensed:
            continue
        found, ru = dict_ru(word)
        if found:
            if ru_looks_like_noun(ru) and not traced_by_stem(ru) \
               and not traced_by_translit(word):
                bad.append(word)
                kinds.append((word, "noun"))
            continue
        # порог 3, не 5: голое «son» ловится как NAME:Son
        if len(word) >= 3 and not traced_by_translit(word):
            bad.append(word)
            kinds.append((word, "offlex"))
    untraced_entities.last_kinds = kinds
    return bad
