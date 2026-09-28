#!/usr/bin/env python3
"""Генератор побайтовых тест-векторов кодека позиции (WP3, слой карты).

ВАЖНО: формат НЕ новый. Точные координаты уже канонизированы в Envelope v0
(§5 спеки docs/RM_Envelope_v0.md, sim/envelope.py: encode_fine_coords):
обе оси квантуются в u24 умножением на 16777215 (2^24 - 1) с округлением
floor(x + 0.5), сериализация — lat LE24 + lon LE24, итого 6 байт.
PositionCodec.swift обязан быть тонкой обёрткой над Envelope.encodeFineCoords —
второго формата координат в проекте быть не должно.

Разрешение: ~1.07e-5° ≈ 1.19 м по широте, ~2.15e-5° ≈ 2.39 м по долготе
на экваторе. Вход вне диапазонов (-90…90, -180…180) — ошибка, не зажим.

Известная граница формата: lat=+90 и lon=+180 кодируются как 0xFFFFFF,
что совпадает с сентинелом «координат нет» (Envelope.noFine). Здесь это
только фиксируется вектором edge_max_sentinel — решение за владельцем.

Запуск: python3 sim/position_codec_vectors_gen.py → перезаписывает
tests/position_codec_vectors.json. Использует sim/envelope.py напрямую —
один источник истины.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from envelope import encode_fine_coords, decode_fine_coords  # noqa: E402

CASES = [
    # (имя, lat, lon)
    ("origin", 0.0, 0.0),
    ("north_pole", 90.0, 0.0),
    ("south_pole", -90.0, 0.0),
    ("antimeridian_neg", 0.0, -180.0),
    ("antimeridian_pos", 0.0, 180.0),   # lon-код 0xFFFFFF == сентинел noFine
    ("casablanca", 33.5731, -7.5898),
    ("gibraltar", 36.1408, -5.3536),
    ("bali_denpasar", -8.65, 115.2167),
    ("hcmc", 10.7626, 106.6602),
    ("one_step_lat", 180.0 / 16777215 * 1 - 90.0, 0.0),   # lat-код == 1
    ("one_step_lon", 0.0, 360.0 / 16777215 * 1 - 180.0),  # lon-код == 1
    ("half_step_rounds_up", 180.0 / 16777215 * 0.5 - 90.0, 0.0),  # floor(x+0.5)
]

# входы, которые обязаны давать ошибку (не зажим!)
REJECT_CASES = [
    ("lat_over", 90.0001, 0.0),
    ("lat_under", -90.0001, 0.0),
    ("lon_over", 0.0, 180.0001),
    ("lon_under", 0.0, -180.0001),
]


def main():
    vectors = []
    for name, lat, lon in CASES:
        data = bytes(encode_fine_coords(lat, lon))
        d_lat, d_lon = decode_fine_coords(data)
        vectors.append({
            "name": name,
            "lat": lat,
            "lon": lon,
            "bytes_hex": data.hex(),
            "decoded_lat": d_lat,
            "decoded_lon": d_lon,
        })
        # инвариант: повторное кодирование декодированного даёт те же байты
        assert bytes(encode_fine_coords(d_lat, d_lon)) == data, name
        # round-trip в пределах полшага квантования
        assert abs(d_lat - lat) <= 90.0 / 16777215 + 1e-12, name
        assert abs(d_lon - lon) <= 180.0 / 16777215 + 1e-12, name

    rejects = []
    for name, lat, lon in REJECT_CASES:
        try:
            encode_fine_coords(lat, lon)
            raise AssertionError(f"{name}: ожидалась ошибка, но кодирование прошло")
        except ValueError:
            rejects.append({"name": name, "lat": lat, "lon": lon})

    out = {
        "spec": "Envelope v0 §5 fine coords: u24 = floor((lat+90)/180*16777215 + 0.5); "
                "u24 = floor((lon+180)/360*16777215 + 0.5); bytes = lat LE24 + lon LE24; "
                "вход вне диапазона — ошибка",
        "vectors": vectors,
        "reject": rejects,
    }
    path = os.path.join(os.path.dirname(__file__), "..", "tests",
                        "position_codec_vectors.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"OK: {len(vectors)} векторов + {len(rejects)} reject → {os.path.normpath(path)}")


if __name__ == "__main__":
    main()
