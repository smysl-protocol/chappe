# -*- coding: utf-8 -*-
"""build_region_gazetteer.py — офлайн-газеттир РЕГИОНОВ для выбора
области скачивания карты (Ф2.2, бриф 31.07). Отдельный от газетира
Софи (gazetteer.bin): здесь нужны bounding box, там — ближайший пункт.

Источники (без сетевых геокодеров — принцип независимости):
- ГОРОДА: GeoNames cities15000.txt (население ≥15 000, ~34 тыс.),
  лицензия CC-BY 4.0. bbox — эвристика из населения той же формулой,
  что в GazetteerStore.radiusKm: 0.01·√pop, кламп [2, 30] км.
- ОБЛАСТИ: Natural Earth 10m admin_1_states_provinces (~4.6 тыс.),
  public domain; bbox — настоящий, из полигонов.

Формат regions_gazetteer.json (массив массивов, компактно):
  {"v": 1, "entries": [[имя_ру, имя_en, страна, вид, население,
                        minLat, minLon, maxLat, maxLon], ...]}
  вид: 0 — город, 1 — область. Население областей = 1_000_000
  (ключ сортировки между мегаполисом и малым городом, не факт).

Запуск: python3 tools/geo/build_region_gazetteer.py
Входные файлы берутся из /tmp (cities15000.txt, ne_admin1_10m.geojson),
при отсутствии — скачиваются. Результат:
ios/Chappe/Chappe/Resources/geo/regions_gazetteer.json
"""
import io
import json
import math
import os
import sys
import urllib.request
import zipfile

TMP = "/tmp"
OUT = os.path.join(os.path.dirname(__file__),
                   "../../ios/Chappe/Chappe/Resources/geo/regions_gazetteer.json")

CITIES_URL = "https://download.geonames.org/export/dump/cities15000.zip"
NE_URL = ("https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
          "master/geojson/ne_10m_admin_1_states_provinces.geojson")
COUNTRY_URL = "https://download.geonames.org/export/dump/countryInfo.txt"


def fetch(path, url, binary=True):
    if os.path.exists(path):
        return
    print("скачиваю", url)
    urllib.request.urlretrieve(url, path)


RUSSIAN_LETTERS = set("абвгдежзийклмнопрстуфхцчшщъыьэюяё")


def cyrillic_first(alternates):
    """Первое РУССКОЕ имя из alternatenames: все буквы — из русского
    алфавита. Просто «есть кириллица» ловило осетинское «Мæскуы» и
    украинские варианты раньше русских."""
    for name in alternates.split(","):
        letters = [ch.lower() for ch in name if ch.isalpha()]
        if letters and all(ch in RUSSIAN_LETTERS for ch in letters):
            return name
    return None


def country_names_ru():
    """Русские имена стран: пробуем Babel (CLDR), иначе английские."""
    path = os.path.join(TMP, "countryInfo.txt")
    fetch(path, COUNTRY_URL)
    en = {}
    for line in open(path, encoding="utf-8"):
        if line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) > 4:
            en[parts[0]] = parts[4]
    try:
        from babel import Locale
        ru = Locale("ru")
        return {code: (ru.territories.get(code) or name)
                for code, name in en.items()}
    except ImportError:
        print("предупреждение: Babel не установлен — имена стран латиницей")
        return en


def russian_names_map():
    """geonameid → русское имя из alternateNamesV2 (isolanguage=ru,
    предпочтение isPreferredName, исторические отброшены). Файл
    ru_names_cities.tsv готовится один раз из alternateNamesV2.zip —
    см. отчёт сессии; без него fallback на эвристику по алфавиту."""
    path = os.path.join(TMP, "ru_names_cities.tsv")
    if not os.path.exists(path):
        print("предупреждение: нет ru_names_cities.tsv — "
              "русские имена по эвристике")
        return {}
    result = {}
    for line in open(path, encoding="utf-8"):
        gid, _, name = line.rstrip("\n").partition("\t")
        result[gid] = name
    return result


def load_cities(countries):
    path_zip = os.path.join(TMP, "cities15000.zip")
    path_txt = os.path.join(TMP, "cities15000.txt")
    if not os.path.exists(path_txt):
        fetch(path_zip, CITIES_URL)
        with zipfile.ZipFile(path_zip) as z:
            z.extractall(TMP)
    ru_names = russian_names_map()
    entries = []
    for line in open(path_txt, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        name, ascii_name, alternates = f[1], f[2], f[3]
        lat, lon = float(f[4]), float(f[5])
        country = countries.get(f[8], f[8])
        population = int(f[14] or 0)
        ru = ru_names.get(f[0]) or cyrillic_first(alternates) or name
        radius_km = min(30, max(2, 0.01 * math.sqrt(max(population, 1))))
        dlat = radius_km / 111.0
        dlon = radius_km / (111.0 * max(0.2, math.cos(math.radians(lat))))
        entries.append([ru, ascii_name, country, 0, population,
                        round(lat - dlat, 3), round(lon - dlon, 3),
                        round(lat + dlat, 3), round(lon + dlon, 3)])
    return entries


def geometry_bbox(geometry):
    min_lat = min_lon = 1e9
    max_lat = max_lon = -1e9

    def walk(coords):
        nonlocal min_lat, min_lon, max_lat, max_lon
        if isinstance(coords[0], (int, float)):
            lon, lat = coords[0], coords[1]
            min_lat, max_lat = min(min_lat, lat), max(max_lat, lat)
            min_lon, max_lon = min(min_lon, lon), max(max_lon, lon)
        else:
            for c in coords:
                walk(c)

    walk(geometry["coordinates"])
    return min_lat, min_lon, max_lat, max_lon


def load_admin1(countries):
    path = os.path.join(TMP, "ne_admin1_10m.geojson")
    fetch(path, NE_URL)
    data = json.load(open(path, encoding="utf-8"))
    entries = []
    for feature in data["features"]:
        p = feature["properties"]
        name_en = p.get("name_en") or p.get("name") or ""
        name_ru = p.get("name_ru") or name_en
        if not name_en and not name_ru:
            continue
        iso = p.get("iso_a2") or ""
        country = countries.get(iso) or p.get("admin") or ""
        min_lat, min_lon, max_lat, max_lon = geometry_bbox(feature["geometry"])
        # области, пересекающие антимеридиан (Чукотка), дают bbox на весь
        # мир — зажимаем до восточной половины, честная деградация
        if max_lon - min_lon > 300:
            min_lon, max_lon = min_lon, 180.0
        entries.append([name_ru, name_en, country, 1, 1_000_000,
                        round(min_lat, 3), round(min_lon, 3),
                        round(max_lat, 3), round(max_lon, 3)])
    return entries


def main():
    countries = country_names_ru()
    cities = load_cities(countries)
    areas = load_admin1(countries)
    entries = cities + areas
    # детерминизм: сортировка по имени, затем по стране
    entries.sort(key=lambda e: (e[0], e[2], e[1]))
    payload = {"v": 1,
               "license": "GeoNames CC-BY 4.0; Natural Earth public domain",
               "entries": entries}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False,
                  separators=(",", ":"))
    size = os.path.getsize(OUT) / 1_000_000
    print(f"записей: {len(entries)} (городов {len(cities)}, "
          f"областей {len(areas)}), файл {size:.1f} МБ")


if __name__ == "__main__":
    sys.exit(main())
