# -*- coding: utf-8 -*-
"""Ферма диктовок: синтез аудио через macOS say (ru_RU Milena).

12 эталонных диктовок + тест-1 + тест-2 + салатная фикстура,
каждая в 3 скоростях (-r 140/180/220) и в варианте «с паузами»
(фразы + тишина 2-8 с, одна пауза 12 с). Выход: WAV PCM 16-бит
22050 моно в out/ + manifest.json.
"""
import json, os, re, subprocess, sys, wave

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
SEMDICT = os.path.join(HERE, "..", "semdict")

TEST1 = ("Слушай мы выезжаем примерно через 40 минут наверное потому что "
         "дождь очень сильный зарядил дорога рядом с рынком снова затоплена "
         "так что мы пойдём через мост встретимся наверху у старого кафе "
         "в 7 или лучше в 7 30 возьми 3 бутылки воды и хлеб потому что "
         "у нас всё закончилось и помни зарядить телефон мой аккумулятор "
         "сдох вчера")
TEST2 = ("Блин я вообще не понимаю что происходит мы ждём его уже часа два "
         "он не отвечает батарея у меня почти села процентов 15 осталось "
         "если через полчаса не появится я поеду один короче передай всем "
         "что встреча переносится на завтра на 9 утра и пусть возьмут "
         "деньги наличными тысячу полторы примерно потому что банкомат "
         "тут не работает")
SALAD = ("Я don't понимать что случиться мы жду у меня есть здесь у 2 0 "
         "батарея садится, могу пропасть только 15 percent ушёл налево "
         "он не ответ если нет 1 appears в 30 минут я идти один pass все "
         "встреча перенести завтра у 9 m взять cash 1000 про 1500 "
         "банкомат не работаю здесь")

RATES = (140, 180, 220)
VOICE = "Milena"
SR = 22050


def texts():
    out = []
    with open(os.path.join(SEMDICT, "dictation_corpus.jsonl"),
              encoding="utf-8") as f:
        for i, line in enumerate(l for l in f if l.strip()):
            out.append((f"corpus{i+1:02d}", json.loads(line)["ru_dictation"]))
    out += [("test1", TEST1), ("test2", TEST2), ("salad", SALAD)]
    return out


def say_to_wav(text, rate, path):
    aiff = path + ".aiff"
    subprocess.run(["say", "-v", VOICE, "-r", str(rate), "-o", aiff, text],
                   check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SR}", "-c", "1",
                    aiff, path], check=True, capture_output=True)
    os.remove(aiff)


def phrases(text, target=9):
    words = text.split()
    return [" ".join(words[i:i + target]) for i in range(0, len(words), target)]


def paused_wav(text, path):
    """Фразы + тишина: 2-8 с по кругу, после второй фразы — 12 с."""
    pauses = [2, 5, 8, 3, 6, 4, 7]
    parts = phrases(text)
    frames = b""
    params = None
    for i, phrase in enumerate(parts):
        piece = path + f".p{i}.wav"
        say_to_wav(phrase, 180, piece)
        with wave.open(piece, "rb") as w:
            params = w.getparams()
            frames += w.readframes(w.getnframes())
        os.remove(piece)
        if i < len(parts) - 1:
            gap = 12 if i == 1 else pauses[i % len(pauses)]
            frames += b"\x00\x00" * int(SR * gap)
    with wave.open(path, "wb") as w:
        w.setparams(params)
        w.writeframes(frames)


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = []
    for name, text in texts():
        for rate in RATES:
            fn = f"{name}_r{rate}.wav"
            say_to_wav(text, rate, os.path.join(OUT, fn))
            manifest.append({"file": fn, "name": name, "rate": rate,
                             "variant": f"r{rate}", "text": text})
        fn = f"{name}_paused.wav"
        paused_wav(text, os.path.join(OUT, fn))
        manifest.append({"file": fn, "name": name, "rate": 180,
                         "variant": "paused", "text": text})
        print(name, "готов (4 варианта)")
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w",
                             encoding="utf-8"), ensure_ascii=False, indent=1)
    print("итого файлов:", len(manifest))


if __name__ == "__main__":
    main()
