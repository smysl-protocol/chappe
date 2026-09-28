#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_gate.py — релизный эвал-гейт линии Софи (шаг 4, паттерн release
gate из waku-agent).

Сертифицирует МОДЕЛЬ за llama-server для харнесса Софи:
  этап 1 (детерминированные проверки, обязателен, планки жёсткие):
    - инструменты: правильный выбор + аргументы + «не звал зря»
      (критичные негативы — обязательны все);
    - гейт памяти: cost-weighted (FN=4×FP, планка 0.5 из waku) на
      кейсах, которые эвристики отдают модели;
    - консолидация: структура, потолки, негативные контроли
      «не выдумывай» (стиль теста 6б SOS).
  этап 2 (LLM-судья, опционален): полезность ответов Софи; без
    ANTHROPIC_API_KEY — SKIPPED, гейт не блокируется (как у waku).

Промпты и схемы — ЕДИНЫЕ эталоны prompts/*: их же сверяет с рантаймом
приложения Swift-замок SophieEvalSyncTests. Сэмплинг — жадный (temp 0,
top_k 1), как .extraction на телефоне.

Запуск (llama-server слушает 8080):
    python3 tools/sophie_eval/run_gate.py --model-name "Qwen3-4B-Q4_K_M"

Вердикт: печать + last_verdict.json; exit 0 = GATE OPEN.
Только стандартная библиотека.
"""

import argparse
import datetime
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from scoring import THRESHOLD, cost_weighted_score

КОРЕНЬ = pathlib.Path(__file__).resolve().parent
РЕПО = КОРЕНЬ.parent.parent
BASE = os.environ.get("SOPHIE_EVAL_BASE", "http://localhost:8080")
ПЛАНКА_ИНСТРУМЕНТОВ = 0.9   # доля верных выборов (критичные — все)
ПЛАНКА_СУДЬИ = 4.0          # средний балл 1..5

# ---------------------------------------------------------------------------
# Эталоны и HTTP
# ---------------------------------------------------------------------------


def эталон(имя):
    return (КОРЕНЬ / "prompts" / имя).read_text(encoding="utf-8").strip()


def кейсы(имя):
    строки = (КОРЕНЬ / "datasets" / имя).read_text(encoding="utf-8")
    return [json.loads(s) for s in строки.splitlines() if s.strip()]


def _post(path, payload, timeout=300):
    req = urllib.request.Request(BASE + path,
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def структурный_вызов(промпт, схема, n_predict=160):
    """/completion с json_schema и жадным сэмплингом — как на телефоне."""
    ответ = _post("/completion", {
        "prompt": промпт,
        "n_predict": n_predict,
        "temperature": 0,
        "top_k": 1,
        "json_schema": json.loads(схема),
        "cache_prompt": True,
    })
    return json.loads(вырезать_json(ответ.get("content", "")))


def вырезать_json(текст):
    """Первый сбалансированный {...} — как StructuredLLM.extractJSONObject."""
    старт = текст.find("{")
    if старт < 0:
        raise ValueError(f"нет JSON в ответе: {текст[:200]!r}")
    глубина, в_строке, экран = 0, False, False
    for i in range(старт, len(текст)):
        ч = текст[i]
        if в_строке:
            if экран:
                экран = False
            elif ч == "\\":
                экран = True
            elif ч == '"':
                в_строке = False
        else:
            if ч == '"':
                в_строке = True
            elif ч == "{":
                глубина += 1
            elif ч == "}":
                глубина -= 1
                if глубина == 0:
                    return текст[старт:i + 1]
    raise ValueError("несбалансированный JSON")

# ---------------------------------------------------------------------------
# Этап 1: детерминированные проверки
# ---------------------------------------------------------------------------


def этап_инструменты():
    шаблон = эталон("selection_prompt.txt")
    схема = эталон("selection_schema.json")
    провалы, критичные_провалы, всего = [], [], 0
    for кейс in кейсы("tools.jsonl"):
        всего += 1
        try:
            ответ = структурный_вызов(
                шаблон.replace("{MESSAGE}", кейс["message"]), схема,
                n_predict=96)
        except Exception as e:
            ответ = {"tool": f"ОШИБКА: {e}"}
        ок = ответ.get("tool") == кейс["expect_tool"]
        for ключ, значение in (кейс.get("expect_in_args") or {}).items():
            ок = ок and str(ответ.get(ключ, "")).strip() == значение
        if not ок:
            (критичные_провалы if кейс.get("critical") else провалы).append(
                f"{кейс['id']}: ждали {кейс['expect_tool']}"
                f"{кейс.get('expect_in_args') or ''}, получили {ответ}")
    доля = (всего - len(провалы) - len(критичные_провалы)) / всего
    прошёл = доля >= ПЛАНКА_ИНСТРУМЕНТОВ and not критичные_провалы
    return {"этап": "инструменты", "прошёл": прошёл,
            "доля": round(доля, 3), "планка": ПЛАНКА_ИНСТРУМЕНТОВ,
            "провалы": провалы, "критичные_провалы": критичные_провалы}


def этап_гейт():
    шаблон = эталон("gate_prompt.txt")
    схема = эталон("gate_schema.json")
    tp = fp = tn = fn = 0
    провалы = []
    for кейс in кейсы("gate.jsonl"):
        if кейс["expected_route"] != "model":
            continue   # эвристики держит Swift-замок SophieGateDatasetTests
        try:
            ответ = структурный_вызов(
                шаблон.replace("{MESSAGE}", кейс["message"]), схема,
                n_predict=96)
            решил = bool(ответ.get("retrieve"))
        except Exception:
            решил = True   # fail-open, как в рантайме
        надо = кейс["should_retrieve"]
        if решил and надо:
            tp += 1
        elif решил and not надо:
            fp += 1
            провалы.append(f"{кейс['id']}: FP — искал зря")
        elif not решил and надо:
            fn += 1
            провалы.append(f"{кейс['id']}: FN — пропустил память (дорого!)")
        else:
            tn += 1
    счёт = cost_weighted_score(tp=tp, fp=fp, tn=tn, fn=fn)
    return {"этап": "гейт памяти", "прошёл": счёт >= THRESHOLD,
            "счёт": round(счёт, 3), "планка": THRESHOLD,
            "матрица": {"tp": tp, "fp": fp, "tn": tn, "fn": fn},
            "провалы": провалы}


def этап_консолидация():
    шапка = эталон("consolidation_header.txt")
    схема = эталон("consolidation_schema.json")
    провалы = []
    for кейс in кейсы("consolidation.jsonl"):
        реплики = "\n".join(
            ("Пользователь: " if r["role"] == "user" else "Софи: ") + r["text"]
            for r in кейс["transcript"])
        try:
            ответ = структурный_вызов(шапка + "\n" + реплики, схема,
                                      n_predict=220)
            факты = ответ.get("facts", [])
            assert isinstance(факты, list) and len(факты) <= 5, "фактов > 5"
            текст_фактов = " ".join(
                f"{f.get('subject', '')} {f.get('content', '')}" for f in факты)
            if кейс["expect_empty_facts"]:
                # Негативный контроль «не выдумывай» (стиль теста 6б SOS)
                assert not факты, f"выдуманы факты: {текст_фактов[:160]}"
            else:
                assert any(м.lower() in текст_фактов.lower()
                           for м in кейс["expect_contains_any"]), \
                    f"нет ни одного из {кейс['expect_contains_any']}: " \
                    f"{текст_фактов[:160]}"
        except Exception as e:
            провалы.append(f"{кейс['id']}: {e}")
    return {"этап": "консолидация", "прошёл": not провалы,
            "провалы": провалы}

# ---------------------------------------------------------------------------
# Этап 2: LLM-судья (опционально)
# ---------------------------------------------------------------------------


def этап_судья():
    ключ = os.environ.get("ANTHROPIC_API_KEY")
    if not ключ:
        return {"этап": "судья", "прошёл": None,
                "заметка": "SKIPPED: нет ANTHROPIC_API_KEY — "
                           "гейт не блокируется (как у waku)"}
    системный = (РЕПО / "ios/Chappe/Chappe/Resources/prompts/"
                        "sophie_system_ru.txt").read_text(encoding="utf-8")
    баллы, провалы = [], []
    for кейс in кейсы("judge.jsonl"):
        ответ_софи = _post("/v1/chat/completions", {
            "messages": [{"role": "system", "content": системный},
                         {"role": "user", "content": кейс["question"]}],
            "max_tokens": 220,
            "temperature": 0.5, "top_p": 0.85, "top_k": 20,
        })["choices"][0]["message"]["content"]
        запрос = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=json.dumps({
                "model": "claude-sonnet-5",
                "max_tokens": 200,
                "messages": [{"role": "user", "content":
                    "Оцени ответ офлайн-ассистента Софи по шкале 1..5 "
                    "(полезность, русский язык, женский род о себе, "
                    "отсутствие выдумок). Ответь ТОЛЬКО JSON "
                    '{"score": 1..5, "reason": "..."}.\n\n'
                    f"Вопрос: {кейс['question']}\n\nОтвет: {ответ_софи}"}],
            }).encode(),
            headers={"Content-Type": "application/json",
                     "x-api-key": ключ,
                     "anthropic-version": "2023-06-01"})
        with urllib.request.urlopen(запрос, timeout=120) as r:
            вердикт = json.loads(вырезать_json(
                json.loads(r.read().decode())["content"][0]["text"]))
        баллы.append(вердикт["score"])
        if вердикт["score"] <= 2:
            провалы.append(f"{кейс['id']}: {вердикт['score']} — "
                           f"{вердикт.get('reason', '')[:160]}")
    средний = sum(баллы) / len(баллы)
    return {"этап": "судья", "прошёл": средний >= ПЛАНКА_СУДЬИ and not провалы,
            "средний": round(средний, 2), "планка": ПЛАНКА_СУДЬИ,
            "баллы": баллы, "провалы": провалы}

# ---------------------------------------------------------------------------


def main():
    парсер = argparse.ArgumentParser()
    парсер.add_argument("--model-name", default=os.environ.get(
        "SOPHIE_EVAL_MODEL", "неназванная модель"))
    арги = парсер.parse_args()

    try:
        _post("/completion", {"prompt": "ping", "n_predict": 1}, timeout=60)
    except Exception as e:
        print(f"КРАСНЫЙ: llama-server на {BASE} не отвечает: {e}")
        sys.exit(1)

    этапы = [этап_инструменты(), этап_гейт(), этап_консолидация(),
             этап_судья()]
    обязательные = [э for э in этапы if э["прошёл"] is not None]
    открыт = all(э["прошёл"] for э in обязательные)

    вердикт = {
        "модель": арги.model_name,
        "когда": datetime.datetime.now().isoformat(timespec="seconds"),
        "сервер": BASE,
        "этапы": этапы,
        "вердикт": "GATE OPEN" if открыт else "GATE CLOSED",
    }
    (КОРЕНЬ / "last_verdict.json").write_text(
        json.dumps(вердикт, ensure_ascii=False, indent=2), encoding="utf-8")

    for э in этапы:
        статус = ("SKIP" if э["прошёл"] is None
                  else "OK" if э["прошёл"] else "FAIL")
        print(f"[{статус:4}] {э['этап']}: "
              + json.dumps({k: v for k, v in э.items()
                            if k not in ("этап", "прошёл")},
                           ensure_ascii=False))
    print(f"\n{вердикт['вердикт']} — {арги.model_name}"
          f" (подробно: tools/sophie_eval/last_verdict.json)")
    sys.exit(0 if открыт else 1)


if __name__ == "__main__":
    main()
