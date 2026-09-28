# -*- coding: utf-8 -*-
"""Покрытие словаря на ЖИВОМ трафике (03.08, решение владельца).

Повод: за два дня радиотестов ни одно живое сообщение не ушло смыслом
— всё откатилось в текст. Три отката из восьми были «больше половины
слов вне словаря». Значит вопрос не в кодеке, а в наполнении словаря,
и на него нужен не спор, а список: КАКИХ СЛОВ НЕ ХВАТАЕТ.

Метод: каждое сообщение прогоняется тем же путём, что в продукте
(пре-гейт → пивот через llama → гейты), фиксируется исход и причина;
для отказов «вне словаря» слова сообщения сверяются со словарём и
недостающие складываются в частотный список.

Запуск: python3 tools/semdict/coverage_measure.py <корпус.json>
"""
import json
import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "dictation_farm"))
sys.path.insert(0, HERE)

import run_farm as F                                    # noqa: E402
import farm_text as FT                                  # noqa: E402

DICT = os.path.join(HERE, "rm_dict_core_v0.json")


def dictionary_stems():
    """Основы русских слов словаря (для грубой проверки покрытия)."""
    raw = json.load(open(DICT, encoding="utf-8"))
    items = raw["entries"] if isinstance(raw, dict) and "entries" in raw else raw
    values = items if isinstance(items, list) else list(items.values())
    stems = set()
    for entry in values:
        ru = str(entry.get("ru", "")).lower()
        for word in re.findall(r"[а-яё]+", ru):
            stems.add(word)
            if len(word) > 4:
                stems.add(word[:-1])
                stems.add(word[:-2])
    return stems


def words_of(text):
    return [w for w in re.findall(r"[а-яё]+", text.lower()) if len(w) > 2]


def covered(word, stems):
    """Слово покрыто, если оно само или его основа есть в словаре."""
    if word in stems:
        return True
    for cut in (1, 2, 3):
        if len(word) - cut >= 3 and word[:-cut] in stems:
            return True
    return False


def main():
    corpus_path = sys.argv[1]
    texts = json.load(open(corpus_path, encoding="utf-8"))
    texts = [t for t in dict.fromkeys(texts) if t and len(t.split()) >= 2]
    stems = dictionary_stems()
    print(f"словарь: {len(stems)} основ; сообщений: {len(texts)}\n")

    outcomes = Counter()
    missing = Counter()
    per_message = []
    for text in texts:
        reason = FT.pre_detect(text)
        result = None
        if reason is None:
            result = FT.encode_with_reason(F, text)
        if isinstance(result, dict) and result.get("outcome") == "semantic":
            outcome = "semantic"
        else:
            outcome = reason or (result.get("reason")
                                 if isinstance(result, dict) else str(result))
        outcomes[str(outcome)[:60]] += 1
        words = words_of(text)
        gaps = [w for w in words if not covered(w, stems)]
        missing.update(gaps)
        per_message.append({
            "text": text, "outcome": str(outcome)[:80],
            "words": len(words), "missing": gaps,
            "coverage": round(1 - len(gaps) / max(len(words), 1), 2),
        })
        print(f"{'✓' if outcome == 'semantic' else '·'} "
              f"покрытие {per_message[-1]['coverage']:.0%} "
              f"| {str(outcome)[:42]:42} | {text[:44]}")

    print("\n— исходы —")
    for reason, count in outcomes.most_common():
        print(f"  {count:3}  {reason}")

    total_words = sum(m["words"] for m in per_message)
    total_missing = sum(len(m["missing"]) for m in per_message)
    print(f"\nпокрытие по словам: {1 - total_missing / max(total_words,1):.1%} "
          f"({total_words - total_missing} из {total_words})")

    print("\n— ЧЕГО НЕ ХВАТАЕТ (топ-40 по частоте) —")
    for word, count in missing.most_common(40):
        print(f"  {count:3}× {word}")

    out = os.path.join(os.path.dirname(corpus_path), "coverage_report.json")
    json.dump({"per_message": per_message,
               "missing": missing.most_common(),
               "outcomes": outcomes.most_common()},
              open(out, "w"), ensure_ascii=False, indent=1)
    print(f"\nподробности → {out}")


if __name__ == "__main__":
    main()
