# -*- coding: utf-8 -*-
"""Ферма, голосовой контур (п.1б): реальные аудио, полный конвейер.

Вход: 200 записей Golos (реальные русские голоса) — распознавания
SFSpeech сделаны на устройстве прошлой фермой (farm_recognized_golos.json,
тем же кодом, что живая диктовка; детерминизм STT доказан бенчем).
TTS-файлы исключены по правилу «TTS не использовать».

Конвейер: прегейт → пивот (llama-server, промпт v1) → гейты → кодек →
рендер приёмника → факт-чекер (вход = STT-текст).
Выход: farm_voice_results.json.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))
os.chdir(os.path.join(HERE, "..", "semdict"))

import farm_text as FT                          # noqa: E402


def load_golos():
    data = json.load(open(os.path.join(HERE, "farm_recognized_golos.json"),
                          encoding="utf-8"))
    rows = []
    for r in data["results"]:
        if not r["file"].startswith("farm_golos"):
            continue                            # TTS-файлы (corpus/test) — мимо
        text = (r.get("text") or "").strip()
        if len(text.split()) >= 3:
            rows.append(dict(file=r["file"], text=text))
    return rows


def main():
    rows = load_golos()
    print(f"golos-записей в контуре: {len(rows)}", flush=True)
    residual = {}
    fixtures = []
    stats = FT.ru_full_pipeline([r["text"] for r in rows],
                                fixtures, residual)
    top = sorted(residual.items(), key=lambda kv: -kv[1])[:100]
    out = dict(voice=stats, residual_top100=top, fixtures=fixtures,
               n_input_files=len(rows))
    path = os.path.join(HERE, "farm_voice_results.json")
    json.dump(out, open(path, "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    pid = stats["latin_tokens"] / stats["tokens"] if stats["tokens"] else 0
    fr = stats["facts_ok"] / stats["facts_all"] if stats["facts_all"] else 0
    print(f"[golos] n={stats['n']} semantic={stats['semantic']} "
          f"text={stats['text']} факты={fr:.1%} пиджин={pid:.1%}")
    print("причины text:", stats["text_reasons"])
    print("итог:", path)


if __name__ == "__main__":
    main()
