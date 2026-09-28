# -*- coding: utf-8 -*-
"""Импорт реальных записей голосового корпуса (протокол
docs/voice_corpus_protocol.md) в фикстуры фермы.

Шаги: конвертация в wav 16 кГц (afconvert) → Documents симулятора
(farm_*.wav) → запуск приложения с --bench-farm (STT SFSpeech тем же
кодом, что живая диктовка) → сборка voice_corpus_v1.jsonl.

Запуск: python3 import_recordings.py <папка с записями>
Имена файлов: <условие>_k<карточка>.<ext>, напр. s_k3.m4a.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = dict(os.environ,
           DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
CONDITIONS = {"q": "тихо", "s": "улица", "w": "ветер",
              "c": "машина", "h": "шёпот"}
# обязательные категории фактов по карточкам протокола
CARD_FACTS = {
    1: ["time", "places"], 2: ["numbers", "entities"],
    3: ["negations"], 4: ["negations"], 5: ["names", "places"],
    6: ["places"], 7: ["numbers", "entities"], 8: ["numbers"],
    9: ["time"], 10: ["entities", "numbers"],
    11: ["numbers", "time", "places", "entities"], 12: ["time"],
}


def run(cmd, **kw):
    return subprocess.run(cmd, env=ENV, capture_output=True, text=True,
                          **kw)


def main():
    if len(sys.argv) != 2:
        sys.exit("нужна папка с записями")
    src = sys.argv[1]
    files = [f for f in sorted(os.listdir(src))
             if re.match(r"[qswch]_k\d+\.", f)]
    if not files:
        sys.exit("не нашёл файлов вида <условие>_k<номер>.*")
    print(f"записей: {len(files)}")

    data_dir = run(["xcrun", "simctl", "get_app_container", "booted",
                    "com.chappe.app", "data"]).stdout.strip()
    if not data_dir:
        sys.exit("симулятор не запущен (simctl boot + установи RM)")
    docs = os.path.join(data_dir, "Documents")

    manifest = []
    for f in files:
        m = re.match(r"([qswch])_k(\d+)\.", f)
        wav = "farm_" + f.rsplit(".", 1)[0] + ".wav"
        # 16 кГц mono wav — как пишет сама диктовка
        r = run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                 os.path.join(src, f), os.path.join(docs, wav)])
        if r.returncode != 0:
            print("конвертация упала:", f, r.stderr.strip()[:80])
            continue
        manifest.append(dict(file=wav, condition=CONDITIONS[m.group(1)],
                             card=int(m.group(2)),
                             required=CARD_FACTS.get(int(m.group(2)), [])))
    print(f"сконвертировано: {len(manifest)} → Documents симулятора")

    run(["xcrun", "simctl", "terminate", "booted", "com.chappe.app"])
    time.sleep(1)
    run(["xcrun", "simctl", "launch", "booted", "com.chappe.app",
         "--bench-farm"])
    out_json = os.path.join(docs, "farm_recognized.json")
    deadline = time.time() + 20 * 60
    while time.time() < deadline:
        if os.path.exists(out_json):
            data = json.load(open(out_json))
            if data.get("done", 0) >= len(manifest):
                break
        time.sleep(10)
    data = json.load(open(out_json))
    texts = {r["file"]: r.get("text", "") for r in data["results"]}

    rows = []
    for m in manifest:
        rows.append(dict(**m, stt=texts.get(m["file"], "")))
    out = os.path.join(HERE, "voice_corpus_v1.jsonl")
    with open(out, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"готово: {out} ({len(rows)} строк) — дальше farm_voice.py")


if __name__ == "__main__":
    main()
