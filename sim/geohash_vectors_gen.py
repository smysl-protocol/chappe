#!/usr/bin/env python3
"""Генератор тест-векторов геохеша (WP4, политика раскрытия координат).

Зачем: грант `.coarse(n)` загрубляет позицию усечением геохеша до n символов
(6 ≈ 1.2 км, 5 ≈ 4.9 км, 4 ≈ 39 км) — В ЭФИР уходит центр ячейки, закодированный
тем же 6-байтовым PositionCodec. Восстановить точную позицию из байтов нельзя.

Алгоритм — стандартный geohash (base32 "0123456789bcdefghjkmnpqrstuvwxyz",
чередование бит: чётные — долгота, нечётные — широта, начиная с долготы).
Swift-реализация обязана давать те же строки и те же центры ячеек.

Запуск: python3 sim/geohash_vectors_gen.py → tests/geohash_vectors.json.
"""

import json
import os

BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"


def geohash_encode(lat, lon, length):
    lat_lo, lat_hi = -90.0, 90.0
    lon_lo, lon_hi = -180.0, 180.0
    result = []
    bit = 0
    ch = 0
    even = True  # чётный бит — долгота
    while len(result) < length:
        if even:
            mid = (lon_lo + lon_hi) / 2
            if lon >= mid:
                ch = (ch << 1) | 1
                lon_lo = mid
            else:
                ch = ch << 1
                lon_hi = mid
        else:
            mid = (lat_lo + lat_hi) / 2
            if lat >= mid:
                ch = (ch << 1) | 1
                lat_lo = mid
            else:
                ch = ch << 1
                lat_hi = mid
        even = not even
        bit += 1
        if bit == 5:
            result.append(BASE32[ch])
            bit = 0
            ch = 0
    return "".join(result), ((lat_lo + lat_hi) / 2, (lon_lo + lon_hi) / 2)


CASES = [
    ("casablanca", 33.5731, -7.5898),
    ("gibraltar", 36.1408, -5.3536),
    ("bali_denpasar", -8.65, 115.2167),
    ("hcmc", 10.7626, 106.6602),
    ("origin", 0.0, 0.0),
    ("near_pole", 89.9, 0.0),
    ("near_antimeridian", 10.0, 179.99),
]


def main():
    vectors = []
    for name, lat, lon in CASES:
        entry = {"name": name, "lat": lat, "lon": lon, "hashes": {}}
        for n in (4, 5, 6, 8):
            h, (clat, clon) = geohash_encode(lat, lon, n)
            entry["hashes"][str(n)] = {
                "geohash": h,
                "cell_center_lat": clat,
                "cell_center_lon": clon,
            }
        vectors.append(entry)

    out = {
        "spec": "standard geohash base32; coarse grant = усечение до n символов, "
                "в эфир уходит центр ячейки через PositionCodec",
        "vectors": vectors,
    }
    path = os.path.join(os.path.dirname(__file__), "..", "tests",
                        "geohash_vectors.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"OK: {len(vectors)} векторов → {os.path.normpath(path)}")


if __name__ == "__main__":
    main()
