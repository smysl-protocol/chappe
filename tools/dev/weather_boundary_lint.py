#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Замок границы погодного источника (docs/weather_pack.md, п.1).

Требование владельца (06.08): единственное место, знающее про
Open-Meteo, — Weather/WeatherRemoteSource.swift (имя типа нейтральное —
остальной код не знает даже имени сервиса). Любая утечка их имён
(URL, параметры их API, идентификаторы их моделей) в другой файл
превращает переезд Б1 → Б2 из «смены URL» в переписывание — этот
скрипт делает утечку красной сборкой, а не находкой при переезде.

Запуск:  python3 tools/dev/weather_boundary_lint.py
Выход 0 — граница цела; 1 — утечка (список на stdout).

Слом для проверки: упомянуть api.open-meteo.com в любом другом
Swift-файле — скрипт обязан покраснеть (проверено при создании).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_DIR = os.path.join(ROOT, "ios", "Chappe", "Chappe")
ALLOWED = os.path.join("Weather", "WeatherRemoteSource.swift")

# Маркеры Open-Meteo: их домен, их имена параметров и моделей.
# Ловим и в коде, и в комментариях: комментарий с их параметром —
# уже чертёж утечки.
MARKERS = re.compile(
    r"open-meteo|openmeteo"
    r"|icon_global|gfs_seamless|gfs_global|dwd_icon|ncep_gfs"
    r"|temperature_2m|wind_speed_10m|wind_direction_10m"
    r"|cloud_cover\b|timeformat=unixtime"
    r"|last_run_initialisation_time",
    re.IGNORECASE)


def main():
    leaks = []
    for base, _dirs, files in os.walk(APP_DIR):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, APP_DIR)
            if rel == ALLOWED:
                continue
            with open(path, encoding="utf-8") as f:
                for line_no, line in enumerate(f, 1):
                    m = MARKERS.search(line)
                    if m:
                        leaks.append((os.path.relpath(path, ROOT),
                                      line_no, m.group(0)))
    if leaks:
        print("ГРАНИЦА НАРУШЕНА — Open-Meteo просочился за пределы источника:")
        for rel, line_no, token in leaks:
            print(f"  {rel}:{line_no}  [{token}]")
        print(f"\nВсего: {len(leaks)}. Разрешён только {ALLOWED}.")
        sys.exit(1)
    print("Граница цела: про внешний сервис знает только " + ALLOWED + ".")
    sys.exit(0)


if __name__ == "__main__":
    main()
