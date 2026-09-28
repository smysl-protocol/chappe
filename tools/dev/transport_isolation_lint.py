#!/usr/bin/env python3
"""Замок на изоляцию транспортных линков (крэш стенда 09.08).

Каждый класс, реализующий TransportLink, обязан быть объявлен
`nonisolated`: колбэки линков живут на собственных очередях, а без
пометки класс под MainActor-по-умолчанию получает ИЗОЛИРОВАННЫЙ deinit —
деаллокация уезжает отдельной джобой на главную очередь и гоняется с
сетевыми колбэками (49 крэшей тест-хоста на стенде ×51, жертва в
репорте: LanLink.__isolated_deallocating_deinit).

Запуск: python3 tools/dev/transport_isolation_lint.py (0 чисто, 1 слом).
Слом проверен 09.08: снятие nonisolated с LanLink красит линт.
"""

import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCES = os.path.join(REPO, "ios/Chappe/Chappe")


def main() -> int:
    problems = []
    seen = 0
    for path in glob.glob(os.path.join(SOURCES, "**/*.swift"), recursive=True):
        text = open(path, encoding="utf-8", errors="ignore").read()
        for m in re.finditer(
                r"^([^\n/]*?)\bclass\s+(\w+)\s*:\s*[^{\n]*\bTransportLink\b",
                text, re.M):
            seen += 1
            if "nonisolated" not in m.group(1):
                rel = os.path.relpath(path, REPO)
                problems.append(
                    f"{rel}: класс {m.group(2)} реализует TransportLink "
                    "без nonisolated — изолированный deinit будет гоняться "
                    "с колбэками (крэш стенда 09.08)")
        # Расширение А4 (09.08): в Transport/ ЛЮБОЙ класс с
        # @unchecked Sendable обязан быть nonisolated — NearbyWiFiChannel
        # (не TransportLink) нёс тот же дефект и первым правилом не
        # ловился. Многострочные объявления сшиваются перед проверкой.
        if "/Transport/" in path:
            joined = re.sub(r"\n\s+", " ", text)
            for m in re.finditer(
                    r"^([^\n/]*?)\bclass\s+(\w+)[^\n]*@unchecked Sendable",
                    joined, re.M):
                seen += 1
                if "nonisolated" not in m.group(1):
                    rel = os.path.relpath(path, REPO)
                    problems.append(
                        f"{rel}: класс {m.group(2)} в Transport/ с "
                        "@unchecked Sendable без nonisolated — класс "
                        "дефекта LanLink/NearbyWiFiChannel (А4, 09.08)")
    if seen == 0:
        print("Линт изоляции линков: реализаций TransportLink не найдено — "
              "протокол переехал? Перенеси замок.")
        return 1
    if problems:
        print("СЛОМ ИЗОЛЯЦИИ ТРАНСПОРТНЫХ ЛИНКОВ:")
        for p in problems:
            print(" -", p)
        return 1
    print(f"Изоляция линков цела: nonisolated у всех ({seen}) "
          "реализаций TransportLink.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
