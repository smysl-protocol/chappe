#!/usr/bin/env python3
"""Генератор тест-векторов гео-математики (WP3, слой карты).

Формулы, которые обязана повторить Swift-реализация (GeoMath.swift):

- Расстояние: гаверсинус на сфере радиуса R = 6371000 м (средний радиус
  Земли). Ошибка против эллипсоида < 0.5 % — для «расстояния по прямой»
  в мессенджере достаточно; маршрутов и навигации в v1 нет.
- Азимут: начальный курс (initial bearing) из точки A в точку B,
  градусы 0..360, 0 = север, по часовой.

Запуск: python3 sim/geo_math_vectors_gen.py → tests/geo_math_vectors.json.
Допуски в тестах: расстояние ±0.5 м либо ±1e-6 относительная, азимут ±0.01°.
"""

import json
import math
import os

R = 6371000.0


def haversine_m(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(a)))


def initial_bearing_deg(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


CASES = [
    ("same_point", 33.5731, -7.5898, 33.5731, -7.5898),
    ("one_degree_lon_equator", 0.0, 0.0, 0.0, 1.0),
    ("one_degree_lat", 0.0, 0.0, 1.0, 0.0),
    ("casablanca_gibraltar", 33.5731, -7.5898, 36.1408, -5.3536),
    ("bali_hcmc", -8.65, 115.2167, 10.7626, 106.6602),
    ("across_antimeridian", 10.0, 179.5, 10.0, -179.5),
    ("to_north_pole", 45.0, 30.0, 90.0, 30.0),
    ("short_100m_scale", 36.1408, -5.3536, 36.1417, -5.3536),
]


def main():
    vectors = []
    for name, lat1, lon1, lat2, lon2 in CASES:
        vectors.append({
            "name": name,
            "from": {"lat": lat1, "lon": lon1},
            "to": {"lat": lat2, "lon": lon2},
            "distance_m": haversine_m(lat1, lon1, lat2, lon2),
            "bearing_deg": initial_bearing_deg(lat1, lon1, lat2, lon2),
        })

    out = {
        "spec": "haversine, sphere R=6371000 m; initial bearing 0..360, 0=N, clockwise",
        "vectors": vectors,
    }
    path = os.path.join(os.path.dirname(__file__), "..", "tests",
                        "geo_math_vectors.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"OK: {len(vectors)} векторов → {os.path.normpath(path)}")


if __name__ == "__main__":
    main()
