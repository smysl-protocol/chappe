#!/usr/bin/env python3
"""Замок приватности статистики оптимизатора (бриф владельца 08.08).

Статистика замен — следы того, КАК ЧЕЛОВЕК ПИШЕТ: класс тот же, что
журнал Софи. Она обязана оставаться на устройстве: не попадать в
транспортный дневник, в отчёты, в отправку и в любые выгрузки.

Замок падает, если тип OptimizerStats (или файл его хранилища)
упомянут в запрещённых местах. Проверяется сломом: допишите
`OptimizerStats.load()` в TransportDiary — замок обязан покраснеть.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "ios" / "Chappe" / "Chappe"

# Где статистике появляться НЕЛЬЗЯ: транспорт (уходит в эфир), дневник
# транспорта, релей, конверт, экспорт корпусов и отчётные выгрузки.
FORBIDDEN_DIRS = ["Transport", "Envelope", "Semantic/DictationCorpus.swift"]
FORBIDDEN_FILES = [
    "Transport/TransportDiary.swift",
    "Chat/DictationCorpus.swift",
    "Semantic/ResidualCounter.swift",   # у него своя выгрузка — не смешивать
]
# Единственные законные места: сам файл статистики, оптимизатор,
# Dev-экран (владелец смотрит глазами) и тесты.
ALLOWED = [
    "Semantic/OptimizerStats.swift",
    "Semantic/TextOptimizer.swift",
    "DevSettingsView.swift",
]

MARKERS = [re.compile(r"\bOptimizerStats\b"),
           re.compile(r"optimizer_stats\.json")]


def dev_screen_is_debug_only() -> str | None:
    """Экран со статистикой обязан отсутствовать в Release целиком.

    Проверяем не «спрятан ли пункт меню», а что весь файл под #if DEBUG:
    иначе срез личной переписки попадёт в бинарь, куда может заглянуть
    кто угодно с устройством в руках.
    """
    path = APP / "DevSettingsView.swift"
    text = path.read_text(encoding="utf-8", errors="ignore")
    body = [ln for ln in text.splitlines()
            if ln.strip() and not ln.strip().startswith("//")]
    if not body or body[0].strip() != "#if DEBUG":
        return ("DevSettingsView.swift: файл НЕ начинается с #if DEBUG — "
                "экран со словами из личной переписки попадёт в Release")
    if body[-1].strip() != "#endif":
        return "DevSettingsView.swift: нет закрывающего #endif"
    return None


def main() -> int:
    bad = []
    if (problem := dev_screen_is_debug_only()) is not None:
        bad.append(problem)
    for path in APP.rglob("*.swift"):
        rel = str(path.relative_to(APP))
        if any(rel.startswith(a) or rel.endswith(a) for a in ALLOWED):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for marker in MARKERS:
            for match in marker.finditer(text):
                line = text[: match.start()].count("\n") + 1
                forbidden = (
                    any(rel.startswith(d) for d in FORBIDDEN_DIRS)
                    or rel in FORBIDDEN_FILES
                )
                where = "ЗАПРЕЩЁННОЕ МЕСТО" if forbidden else "вне разрешённых"
                bad.append(f"{rel}:{line}: {match.group(0)} — {where}")

    if bad:
        print("Статистика оптимизатора утекает из личных данных:")
        for line in bad:
            print("  " + line)
        print("\nЭто следы того, как человек пишет. Она остаётся на "
              "устройстве: не в дневнике, не в отчётах, не в отправке.")
        return 1
    print("Статистика оптимизатора на месте: только хранилище, оптимизатор "
          "и Dev-экран.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
