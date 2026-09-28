#!/usr/bin/env python3
"""Замок на КОРЕНЬ виса ветра (поручение владельца 09.08).

Дроссель тиков (tickDT) держит замок subBudgetFramesAreSkipped, но он —
предохранитель, не корень. Корень — структурные инварианты рендера
частиц, и этот линт держит их текстом исходника:

 1. ЯКОРЬ РАСПИСАНИЯ НЕ ПРОИЗВОДЕН ОТ ПЕРЕРИСОВКИ. `.periodic(from:)`
    обязан ссылаться на @State-переменную. `.now`/`Date()` в якоре —
    свежий якорь при каждой пересборке body → немедленный тик → мутация
    → пересборка → петля, вешавшая главный поток (вис 08.08).

 2. ТЕЛО ОТРИСОВКИ НЕ ПИШЕТ СОСТОЯНИЕ. Внутри Canvas-замыкания нет
    присваиваний @State-переменным и нет Task/DispatchQueue (отложенная
    запись — та же запись): запись из draw — самостоятельный повод
    перерисовки, вторая половина той же петли.

Запуск: python3 tools/dev/wind_render_lint.py  (0 — чисто, 1 — слом).
Слом проверен 09.08 в обе стороны: якорь на .now и запись состояния в
Canvas красят линт по отдельности (см. отчёт сессии).
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(REPO, "ios/Chappe/Chappe/Weather/WindParticles.swift")


def strip_comments(text):
    """Убрать строчные комментарии: история починки в комментариях
    поминает запрещённые формы — линт судит только код."""
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


def canvas_block(text):
    """Тело Canvas { ... } — по балансу скобок от первого `Canvas {`."""
    start = text.find("Canvas {")
    if start < 0:
        return None
    i = text.find("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return None


def main() -> int:
    try:
        text = strip_comments(open(SOURCE, encoding="utf-8").read())
    except OSError:
        print(f"Линт ветра: не найден исходник {SOURCE}")
        return 1
    problems = []

    # --- Инвариант 1: якорь расписания
    anchors = re.findall(r"\.periodic\(\s*from:\s*([^,]+),", text)
    if not anchors:
        problems.append("TimelineView с .periodic не найден — рендер "
                        "частиц переехал? Перенеси замок вместе с ним.")
    state_vars = set(re.findall(r"@State\s+(?:private\s+)?var\s+(\w+)", text))
    for anchor in anchors:
        expr = anchor.strip()
        if expr in {".now", "Date()"} or "Date(" in expr:
            problems.append(f"якорь расписания «{expr}» производен от "
                            "перерисовки: свежий якорь на каждую пересборку "
                            "body = петля виса 08.08")
        elif expr not in state_vars:
            problems.append(f"якорь расписания «{expr}» не @State-переменная "
                            "— стабильность якоря не гарантирована")

    # --- Инвариант 2: тело отрисовки не пишет состояние
    block = canvas_block(text)
    if block is None:
        problems.append("Canvas-замыкание не найдено — рендер частиц "
                        "переехал? Перенеси замок вместе с ним.")
    else:
        for name in state_vars:
            if re.search(rf"\b{name}\s*=[^=]", block):
                problems.append(f"тело отрисовки пишет состояние «{name}» — "
                                "запись из draw есть повод перерисовки "
                                "(петля виса 08.08)")
        for banned in ("Task {", "Task{", "DispatchQueue"):
            if banned in block:
                problems.append(f"тело отрисовки содержит «{banned}» — "
                                "отложенная запись состояния из draw "
                                "запрещена тем же инвариантом")

    if problems:
        print("СЛОМ ИНВАРИАНТА РЕНДЕРА ВЕТРА:")
        for p in problems:
            print(" -", p)
        return 1
    print("Инвариант рендера ветра цел: якорь стабилен, "
          "тело отрисовки состояния не пишет.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
