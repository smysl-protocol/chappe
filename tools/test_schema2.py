#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
R+M · Structured output, версия 2
Что изменилось против v1:
  - у списка needs жёсткий потолок (maxItems) — лечит зацикливание
  - убран неработающий на этой сборке путь response_format
  - добавлена автопроверка ответа против эталона
  - 3 прогона подряд — видно стабильность

Запуск (сервер на :8080 должен работать):
    python3 test_schema2.py
"""

import json
import urllib.request
import urllib.error

BASE = "http://localhost:8080"
RUNS = 3

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
            "minItems": 1,
            "maxItems": 4,                      # <-- потолок против зацикливания
            "items": {"type": "string",
                      "enum": ["bandages", "water", "food", "boat", "vehicle",
                               "doctor", "medicine", "evacuation", "fuel", "shelter"]}
        }
    },
    "required": ["type", "severity", "people_count", "injury", "needs"],
    "additionalProperties": False
}

PROMPT = (
    "Ты обрабатываешь сигнал бедствия. Извлеки факты из сообщения и заполни поля.\n"
    "Правила: type=sos если нужна срочная помощь. severity=critical если есть угроза "
    "жизни. injury — главная травма. needs — только то, что прямо просят.\n\n"
    "Сообщение: " + MSG + "\n\nОтвет:"
)

# эталон: (поле, ожидаемое значение)
ETALON = {
    "type": "sos",
    "severity": "critical",
    "people_count": 3,
    "injury": "bleeding",
}
NEEDS_MUST = {"bandages", "boat"}


def post(path, payload):
    req = urllib.request.Request(BASE + path,
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read().decode()), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}: {e.read().decode()[:400]}"
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


def run_once(i):
    resp, err = post("/completion", {
        "prompt": PROMPT,
        "n_predict": 200,
        "temperature": 0.2,
        "json_schema": SCHEMA,
    })
    print(f"\n--- прогон {i} " + "-" * 45)
    if err:
        print("ОШИБКА:", err)
        return None

    raw = resp.get("content", "")
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        print("не разобрался JSON:", raw[:300])
        return None

    print(json.dumps(obj, ensure_ascii=False, indent=1))

    # автопроверка
    score = 0
    for k, want in ETALON.items():
        got = obj.get(k)
        ok = (got == want)
        score += ok
        print(f"  {'OK ' if ok else 'НЕТ'} {k}: получено {got!r}, нужно {want!r}")

    needs = set(obj.get("needs", []))
    ok_needs = NEEDS_MUST.issubset(needs)
    score += ok_needs
    print(f"  {'OK ' if ok_needs else 'НЕТ'} needs: {sorted(needs)}, "
          f"нужны как минимум {sorted(NEEDS_MUST)}")
    print(f"  ИТОГО: {score}/5")
    return score


print("=" * 60)
print(" ЖЁСТКАЯ СХЕМА С ПОТОЛКОМ СПИСКА · " + str(RUNS) + " прогона")
print("=" * 60)

scores = [s for s in (run_once(i + 1) for i in range(RUNS)) if s is not None]

print("\n" + "=" * 60)
if scores:
    print(f" РЕЗУЛЬТАТ: {scores} из 5 · среднее {sum(scores)/len(scores):.1f}")
    if min(scores) == 5:
        print(" Модель годится для извлечения структуры.")
    elif max(scores) >= 4:
        print(" Близко, но нестабильно — смотри, какое поле плавает.")
    else:
        print(" Смысл извлекается плохо, одной схемы недостаточно.")
else:
    print(" Все прогоны упали — смотри текст ошибки выше.")
print("=" * 60)
