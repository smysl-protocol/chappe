# -*- coding: utf-8 -*-
"""Прогон рода ассистента (Ф1-доп, 30.07.2026).

Живой баг: «Я ошибся» и «стараюсь быть точной» в одном ответе — род не
был задан в персоне. После правки персона-промпта этот скрипт гоняет
три вопроса, где по конструкции обязано появиться прошедшее время от
первого лица, и проверяет: женские формы есть, мужских нет. Затем те
же вопросы по-английски — убедиться, что там ничего не поехало.

Запуск (llama-server на 8080, тот же, что для bench_http.py):
    python3 tools/bench_gender.py
"""

import json
import re
import sys
import urllib.request
from pathlib import Path

BASE = "http://localhost:8080"
PROMPT_FILE = Path(__file__).parent.parent / \
    "ios/Chappe/Chappe/Resources/prompts/sophie_system_ru.txt"

# Жадное декодирование — как в служебных вызовах приложения (temp 0)
SAMPLING = {"temperature": 0, "top_k": 1}

# Вопросы, вынуждающие прошедшее время от первого лица
ВОПРОСЫ_RU = [
    "Ты вчера назвала мне неверное время. Признай ошибку одним "
    "коротким предложением от первого лица.",
    "Скажи одним предложением от первого лица в прошедшем времени, "
    "что ты уже разобралась в моей просьбе и готова помочь.",
    "Ответь одним предложением, начиная со слова «Я» и глагола в "
    "прошедшем времени: ты нашла ответ на мой вчерашний вопрос?",
]

ВОПРОСЫ_EN = [
    "Yesterday you told me the wrong time. Admit the mistake in one "
    "short sentence in the first person.",
    "Say in one sentence, first person past tense, that you have "
    "understood my request and are ready to help.",
    "Answer in one sentence starting with 'I': did you find the "
    "answer to my question from yesterday?",
]

# Мужские формы первого лица — недопустимы. Границы слова вручную:
# «понял» не должен ловиться внутри «поняла».
МУЖСКИЕ = ["ошибся", "понял", "нашёл", "нашел", "уверен", "готов",
           "рад", "точен", "разобрался", "сказал", "назвал", "смог",
           "увидел", "ответил"]
ЖЕНСКИЕ = ["ошиблась", "поняла", "нашла", "уверена", "готова", "рада",
           "точна", "разобралась", "сказала", "назвала", "смогла",
           "увидела", "ответила"]


def мужские_формы(текст):
    найдено = []
    for форма in МУЖСКИЕ:
        if re.search(r"(?<![а-яёА-ЯЁ])" + форма + r"(?![а-яёА-ЯЁ])",
                     текст, re.IGNORECASE):
            найдено.append(форма)
    return найдено


def женские_формы(текст):
    return [ф for ф in ЖЕНСКИЕ
            if re.search(r"(?<![а-яёА-ЯЁ])" + ф + r"(?![а-яёА-ЯЁ])",
                         текст, re.IGNORECASE)]


def спросить(система, вопрос):
    payload = {
        "messages": [{"role": "system", "content": система},
                     {"role": "user", "content": вопрос}],
        "max_tokens": 120, **SAMPLING,
    }
    req = urllib.request.Request(
        BASE + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        resp = json.loads(r.read().decode())
    return resp["choices"][0]["message"]["content"].strip()


def main():
    система = PROMPT_FILE.read_text(encoding="utf-8")
    провалов = 0

    print("=== Русские фикстуры (род обязан быть женским) ===")
    for i, вопрос in enumerate(ВОПРОСЫ_RU, 1):
        ответ = спросить(система, вопрос)
        муж = мужские_формы(ответ)
        жен = женские_формы(ответ)
        ок = not муж and жен
        if not ок:
            провалов += 1
        print(f"[{i}] {'OK' if ок else 'ПРОВАЛ'} — {ответ!r}")
        print(f"    женские: {жен or '—'}; мужские: {муж or '—'}")

    print("\n=== Английские фикстуры (ничего не должно поехать) ===")
    for i, вопрос in enumerate(ВОПРОСЫ_EN, 1):
        ответ = спросить(система, вопрос)
        муж = мужские_формы(ответ)
        ок = bool(ответ) and not муж
        if not ок:
            провалов += 1
        print(f"[{i}] {'OK' if ок else 'ПРОВАЛ'} — {ответ!r}")

    print(f"\nИтог: {'все проверки прошли' if провалов == 0 else str(провалов) + ' провалов'}")
    return 0 if провалов == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
