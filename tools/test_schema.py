#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
R+M · Проверка structured output на llama-server
Сравнивает свободный режим и жёсткую схему. Печатает сырой ответ при ошибке.

Запуск (сервер должен работать на :8080):
    python3 test_schema.py
"""

import json
import urllib.request
import urllib.error

BASE = "http://localhost:8080"

MSG = ("Мы на северном пляже за третьим пирсом, у моего друга сильно порезана нога, "
       "кровь не останавливается уже минут двадцать, нас тут трое, аптечки нет, "
       "телефон почти сел, нужен кто-то с бинтами и лодка чтобы вывезти.")

SCHEMA = {
    "type": "object",
    "properties": {
        "type":         {"type": "string", "enum": ["sos", "medical", "info"]},
        "severity":     {"type": "string", "enum": ["low", "medium", "high", "critical"]},
        "people_count": {"type": "integer", "minimum": 0, "maximum": 31},
        "injury":       {"type": "string", "enum": ["none", "bleeding", "fracture",
                                                     "burn", "head", "unconscious", "other"]},
        "needs": {
            "type": "array",
            "items": {"type": "string",
                      "enum": ["bandages", "water", "food", "boat", "vehicle",
                               "doctor", "medicine", "evacuation", "fuel", "shelter"]}
        }
    },
    "required": ["type", "severity", "people_count", "injury", "needs"],
    "additionalProperties": False
}

ETALON = {
    "severity": "critical (кровь не останавливается 20 мин)",
    "people_count": 3,
    "injury": "bleeding",
    "needs": "bandages + boat",
}


def post(path, payload):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read().decode()), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read().decode()[:600]}"
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


def extract(resp):
    """Достаёт текст из ответа любого из двух эндпоинтов."""
    if resp is None:
        return None
    if "choices" in resp:
        return resp["choices"][0]["message"]["content"]
    if "content" in resp:
        return resp["content"]
    return json.dumps(resp, ensure_ascii=False)[:600]


def strip_think(text):
    """Убирает служебные <think>...</think>, если модель их вывела."""
    if text and "</think>" in text:
        text = text.split("</think>", 1)[1]
    return (text or "").strip()


def show(title, text):
    print("\n" + "=" * 60)
    print(" " + title)
    print("=" * 60)
    print(text if text else "(пусто)")


# --- A. Свободный режим -------------------------------------------------------
resp, err = post("/v1/chat/completions", {
    "messages": [{"role": "user", "content":
        "Извлеки из сообщения структурированный SOS. Ответь ТОЛЬКО валидным JSON "
        "с полями type, severity, people_count, injury, needs. Сообщение: " + MSG}],
    "max_tokens": 400,
    "temperature": 0.3,
})
show("A. СВОБОДНЫЙ РЕЖИМ", err or strip_think(extract(resp)))

# --- B. Схема через chat/completions ------------------------------------------
resp, err = post("/v1/chat/completions", {
    "messages": [{"role": "user", "content": "Извлеки структурированный SOS: " + MSG}],
    "max_tokens": 400,
    "temperature": 0.3,
    "response_format": {
        "type": "json_schema",
        "json_schema": {"name": "sos", "schema": SCHEMA},
    },
})
b_ok = err is None
show("B. ЖЁСТКАЯ СХЕМА (способ 1: response_format)",
     err or strip_think(extract(resp)))

# --- C. Схема через /completion (запасной способ) -----------------------------
if not b_ok:
    resp, err = post("/completion", {
        "prompt": ("Извлеки структурированный SOS из сообщения и верни JSON.\n"
                   "Сообщение: " + MSG + "\nJSON:"),
        "n_predict": 400,
        "temperature": 0.3,
        "json_schema": SCHEMA,
    })
    show("C. ЖЁСТКАЯ СХЕМА (способ 2: /completion + json_schema)",
         err or strip_think(extract(resp)))

# --- Эталон -------------------------------------------------------------------
print("\n" + "=" * 60)
print(" ЧТО ДОЛЖНО БЫТЬ (проверь глазами)")
print("=" * 60)
for k, v in ETALON.items():
    print(f"  {k:14} = {v}")
print("=" * 60)
