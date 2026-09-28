# -*- coding: utf-8 -*-
"""build_map_styles.py — сборка бандл-стилей карты (Ф3, бриф 31.07).

Правка стиля MapLibre — это правка JSON, не кода (требование брифа).
Берём официальные стили OpenFreeMap и поднимаем контраст:

- ТЁМНЫЙ (база: styles/dark): дороги там буквально чёрные (#181818,
  hsl 7%) на фоне rgb(12,12,12), подписи — серые 40% с чёрным гало.
  На улице при свете не разобрать ничего. Осветляем дороги, подписи
  и границы, воду отделяем от суши.
- СВЕТЛЫЙ (база: styles/bright): дневной стиль, почти как есть —
  он изначально контрастный; слегка усиливаем гало подписей.

Тайлы/glyphs/sprite остаются на openfreemap — векторные ДАННЫЕ общие
для обоих стилей, офлайн-паки хранят тайлы по URL (стиль — деталь
рендера). Итог: ios/Chappe/Chappe/Resources/map_styles/style_{dark,light}.json

Запуск: python3 tools/map/build_map_styles.py
Входные ofm_dark.json/ofm_bright.json берутся из /tmp, при
отсутствии скачиваются.
"""
import json
import os
import urllib.request

TMP = "/tmp"
OUT_DIR = os.path.join(os.path.dirname(__file__),
                       "../../ios/Chappe/Chappe/Resources/map_styles")
BASE = "https://tiles.openfreemap.org/styles/"

# Тёмный: осветление дорог/подписей/границ. Ключ — id слоя.
DARK_PAINT = {
    "background": {"background-color": "rgb(16,17,20)"},
    "water": {"fill-color": "rgb(30,36,48)"},
    "waterway": {"line-color": "rgb(30,36,48)"},
    "highway_path": {"line-color": "#46464c"},
    "highway_minor": {"line-color": "#4b4b52"},
    "highway_major_subtle": {"line-color": "#55555c"},
    "highway_major_casing": {"line-color": "rgba(20,20,24,0.9)"},
    "highway_major_inner": {"line-color": "hsl(220,5%,62%)"},
    "highway_motorway_casing": {"line-color": "rgba(20,20,24,0.9)"},
    "highway_motorway_inner": {"line-color": ["interpolate", ["linear"],
        ["zoom"], 5.8, "hsla(0,0%,85%,0.53)", 6, "hsl(35,30%,68%)"]},
    "highway_motorway_subtle": {"line-color": "#5a5a62"},
    "road_pier": {"line-color": "#3a3a40"},
    "railway_transit": {"line-color": "#3c3c44"},
    "railway_service": {"line-color": "#3c3c44"},
    "railway": {"line-color": "#44444c"},
    "boundary_state": {"line-color": "hsl(0,0%,42%)"},
    "boundary_country_z0-4": {"line-color": "hsl(0,0%,48%)"},
    "boundary_country_z5-": {"line-color": "hsl(0,0%,48%)"},
    "water_name": {"text-color": "hsla(210,30%,70%,0.9)",
                   "text-halo-color": "rgba(10,12,16,0.8)"},
    "highway_name_other": {"text-color": "rgba(180,180,186,1)",
                           "text-halo-color": "rgba(10,10,12,1)",
                           "text-halo-width": 1.2},
    "highway_name_motorway": {"text-color": "hsl(0,0%,72%)",
                              "text-halo-color": "rgba(10,10,12,1)",
                              "text-halo-width": 1.2},
}
# Все place_* подписи — одним правилом (они одинаковые)
DARK_PLACE_PAINT = {"text-color": "rgb(212,214,220)",
                    "text-halo-color": "rgba(8,8,10,0.85)",
                    "text-halo-width": 1.3}

# Светлый: bright уже контрастный; чуть плотнее гало подписей,
# чтобы читались на солнце поверх пёстрой подложки.
LIGHT_SYMBOL_HALO = {"text-halo-width": 1.4}


def fetch(path, url):
    if not os.path.exists(path):
        print("скачиваю", url)
        urllib.request.urlretrieve(url, path)
    return json.load(open(path, encoding="utf-8"))


def build_dark():
    style = fetch(os.path.join(TMP, "ofm_dark.json"), BASE + "dark")
    style["name"] = "Chappe Dark (контраст)"
    for layer in style["layers"]:
        lid = layer.get("id", "")
        paint = layer.setdefault("paint", {})
        if lid in DARK_PAINT:
            paint.update(DARK_PAINT[lid])
        elif lid.startswith("place_"):
            paint.update(DARK_PLACE_PAINT)
    return style


def build_light():
    style = fetch(os.path.join(TMP, "ofm_bright.json"), BASE + "bright")
    style["name"] = "Chappe Light (день)"
    for layer in style["layers"]:
        if layer.get("type") == "symbol":
            paint = layer.setdefault("paint", {})
            if "text-halo-color" in paint or "text-color" in paint:
                paint.update(LIGHT_SYMBOL_HALO)
    return style


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, style in [("style_dark.json", build_dark()),
                        ("style_light.json", build_light())]:
        path = os.path.join(OUT_DIR, name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(style, f, ensure_ascii=False, separators=(",", ":"))
        print(name, os.path.getsize(path) // 1000, "КБ")


if __name__ == "__main__":
    main()
