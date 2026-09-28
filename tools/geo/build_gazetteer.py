# -*- coding: utf-8 -*-
"""build_gazetteer.py — собирает офлайн-газетир для Каи.

Источник: GeoNames (download.geonames.org/export/dump/), лицензия CC-BY 4.0.
Берём cities500.txt (все пункты с населением ≥500); если недоступен —
fallback на cities15000.txt.

Имя пункта: если среди alternatenames есть вариант с кириллицей — берём
его (первый), иначе основное имя. Названия стран — по-русски через Babel
(CLDR); нет русского — английское из countryInfo.txt.

Формат gazetteer.bin (little-endian, детерминированный — сортировка по
geonameid):
  магия "RMGZ", версия u8=1
  число стран u16; страны подряд: длина u8 + utf8
  число пунктов u32; пункты подряд:
    lat i32 (градусы × 1e5), lon i32, население u32,
    индекс страны u16, длина имени u8 + utf8

Запуск: python3 tools/geo/build_gazetteer.py
Результат кладётся в ios/Chappe/Chappe/Resources/geo/gazetteer.bin
"""
import io
import os
import struct
import sys
import urllib.request
import zipfile

BASE = "https://download.geonames.org/export/dump/"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "ios/Chappe/Chappe/Resources/geo/gazetteer.bin")


def fetch(name):
    print(f"качаю {name}…")
    with urllib.request.urlopen(BASE + name, timeout=120) as r:
        return r.read()


def load_cities():
    """cities500, при недоступности — cities15000 (fallback по заданию)."""
    for name in ("cities500.zip", "cities15000.zip"):
        try:
            data = fetch(name)
            txt = name.replace(".zip", ".txt")
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                return z.read(txt).decode("utf-8"), name
        except Exception as e:
            print(f"  {name} недоступен: {e}")
    raise SystemExit("ни один источник GeoNames не доступен")


def has_cyrillic(s):
    return any("Ѐ" <= ch <= "ԯ" for ch in s)


def russian_name(name, alternates):
    """Первый кириллический вариант из alternatenames, иначе основное имя."""
    for alt in alternates.split(","):
        alt = alt.strip()
        if alt and has_cyrillic(alt):
            return alt
    return name


def country_names():
    """Код страны -> русское название (Babel/CLDR), иначе английское."""
    info = fetch("countryInfo.txt").decode("utf-8")
    english = {}
    for line in info.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        cols = line.split("\t")
        if len(cols) > 4:
            english[cols[0]] = cols[4]
    try:
        from babel import Locale
        ru = Locale("ru").territories
    except Exception:
        ru = {}
    return {code: ru.get(code, en) for code, en in english.items()}


def main():
    cities_txt, source = load_cities()
    countries = country_names()

    rows = []
    for line in cities_txt.splitlines():
        cols = line.split("\t")
        if len(cols) < 15:
            continue
        geonameid = int(cols[0])
        name = russian_name(cols[1], cols[3])
        lat, lon = float(cols[4]), float(cols[5])
        country = cols[8]
        population = int(cols[14] or 0)
        rows.append((geonameid, name, lat, lon, country, population))

    rows.sort(key=lambda r: r[0])   # детерминизм: сортировка по geonameid

    # Таблица стран — только встречающиеся, отсортированы по коду
    used = sorted({r[4] for r in rows})
    country_index = {code: i for i, code in enumerate(used)}

    buf = io.BytesIO()
    buf.write(b"RMGZ")
    buf.write(struct.pack("<B", 1))
    buf.write(struct.pack("<H", len(used)))
    for code in used:
        name = countries.get(code, code).encode("utf-8")[:255]
        buf.write(struct.pack("<B", len(name)))
        buf.write(name)
    buf.write(struct.pack("<I", len(rows)))
    skipped = 0
    for _, name, lat, lon, country, population in rows:
        nb = name.encode("utf-8")[:255]
        # не резать многобайтовый символ на границе 255
        while nb and (nb[-1] & 0xC0) == 0x80 and len(nb) == 255:
            nb = nb[:-1]
        try:
            buf.write(struct.pack("<iiIH", int(round(lat * 1e5)),
                                  int(round(lon * 1e5)),
                                  min(population, 0xFFFFFFFF),
                                  country_index[country]))
        except struct.error:
            skipped += 1
            continue
        buf.write(struct.pack("<B", len(nb)))
        buf.write(nb)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(buf.getvalue())

    size = os.path.getsize(OUT)
    print(f"источник: {source}; пунктов: {len(rows)}; стран: {len(used)}; "
          f"пропущено: {skipped}")
    print(f"gazetteer.bin: {size:,} байт ({size / 1e6:.1f} МБ) → {OUT}")


if __name__ == "__main__":
    main()
