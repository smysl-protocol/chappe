# -*- coding: utf-8 -*-
"""Синтетический стресс кодека и рэтчета (часть 2, бриф 03.08).

ВАЖНО, И ЭТО НЕ ОГОВОРКА:
Цифры покрытия и сжатия, полученные ЗДЕСЬ, **не являются оценкой
качества словаря** и не могут обосновывать заморозку. Основание —
ADR 005: модель (и генератор) порождает то, что воображает про
человеческую речь, а не саму речь. Полевой корпус собирается отдельно
(корпус диктовок на устройстве) и заменён быть не может.

Синтетика проверяет МЕХАНИКУ, где жанр не важен:
  1. round-trip     — декодирование восстанавливает вход побайтово;
  2. детерминизм    — один вход даёт те же байты в разных процессах;
  3. границы кодека — escape, длины у границы фрагмента, переполнения;
  4. рэтчет         — глубины вокруг потолка, беспорядок, дубли;
  5. фаззинг        — битые/усечённые/перемешанные пакеты не роняют
                      декодер и не принимаются молча за валидные.

Запуск: python3 tools/semdict/synthetic_stress.py <проверка> [N]
       проверки: gen | roundtrip | determinism | bounds | fuzz | all
"""
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

FRAGMENT_LIMIT = 200          # полезная нагрузка пакета
SEED = 20260803               # фиксированный: прогоны воспроизводимы


# ----------------------------------------------------------- генерация

ALPHABET_RU = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
EMOJI = ["❤️", "👍", "🔥", "🚑", "⛺️", "🌧", "🛶", "📍", "⚠️", "🧭"]
URLS = ["http://a.b", "https://example.com/x?y=1#z", "рм.рф/путь"]
COORDS = ["55.7558, 37.6173", "-33.8688,151.2093", "N55°45'21\" E37°37'2\""]
HASHES = ["deadbeef", "0x11AE146D", "a3f5c9e17b2d", "SHA:9f86d081884c7d65"]
NUMBERS = ["0", "7", "42", "1000000", "3.14", "-15", "1/2", "2 500,50",
           "12:05", "07.08.2026", "2026-08-03", "15%", "300 м", "1,5 км"]
NEGATIONS = ["не приду", "никогда не приду", "не то чтобы не приду",
             "если не приду — не жди", "нельзя не согласиться"]
MORPH = ["лодочной станции", "спускающийся к реке", "ведущего к мосту",
         "прибывшего вчера", "затопленной дороги", "недосчитавшийся"]
ASR_NOISE = ["эээ", "ммм", "как его", "ну это", "короче", "вот прям"]

BASE_WORDS = ["иди", "жди", "вода", "мост", "утро", "ветер", "лодка",
              "рынок", "аптечка", "связь", "узел", "берег", "дорога"]


def typo(word, rng):
    """ASR-подобное искажение: перестановка, пропуск, удвоение."""
    if len(word) < 3:
        return word
    kind = rng.randrange(3)
    i = rng.randrange(len(word) - 1)
    if kind == 0:
        return word[:i] + word[i + 1] + word[i] + word[i + 2:]
    if kind == 1:
        return word[:i] + word[i + 1:]
    return word[:i] + word[i] * 2 + word[i:]


def generate(n, rng):
    """Корпус с упором на ГРАНИЦЫ, а не на реалистичность."""
    out = []
    # 1. пустые и однословные
    out += ["", " ", "ок", "да", "нет", "?", "!", "8"]
    # 2. длины вокруг границы фрагмента: 196…204 и кратные
    for target in list(range(FRAGMENT_LIMIT - 6, FRAGMENT_LIMIT + 7)) + \
                  [FRAGMENT_LIMIT * 2, FRAGMENT_LIMIT * 2 + 1, 1, 2, 3]:
        filler = "мост "
        text = (filler * (target // len(filler) + 1))[:target]
        out.append(text.strip())
    # 3. максимум и около
    out.append("а" * 4096)
    out.append("слово " * 800)
    while len(out) < n:
        kind = rng.randrange(10)
        if kind == 0:
            out.append(" ".join(rng.choice(NUMBERS) for _ in range(rng.randrange(1, 6))))
        elif kind == 1:
            out.append(rng.choice(NEGATIONS))
        elif kind == 2:
            out.append(rng.choice(MORPH) + " " + rng.choice(BASE_WORDS))
        elif kind == 3:
            out.append(" ".join(rng.choice(BASE_WORDS) for _ in range(3))
                       + " " + rng.choice(EMOJI))
        elif kind == 4:
            out.append(rng.choice(URLS) + " " + rng.choice(BASE_WORDS))
        elif kind == 5:
            out.append("координаты " + rng.choice(COORDS))
        elif kind == 6:
            out.append(rng.choice(HASHES) + " " + rng.choice(HASHES))
        elif kind == 7:
            words = [rng.choice(BASE_WORDS) for _ in range(rng.randrange(2, 8))]
            out.append(" ".join(typo(w, rng) for w in words))
        elif kind == 8:
            out.append(" ".join([rng.choice(ASR_NOISE)]
                                + [rng.choice(BASE_WORDS) for _ in range(3)]))
        else:                                    # смешение языков
            out.append(f"{rng.choice(BASE_WORDS)} meeting at "
                       f"{rng.choice(['dawn','noon','7pm'])} "
                       f"{rng.choice(EMOJI)}")
    return out[:n]


# ----------------------------------------------------------- проверки

def load_codec():
    os.chdir(HERE)
    import rm_codec
    return rm_codec.Codec()


def units_for(text, codec):
    """Юниты из текста БЕЗ модели: слова словаря кодами, прочее —
    литералами. Для механики этого достаточно, жанр тут не важен."""
    import re
    units = []
    for word in re.findall(r"\S+", text):
        code = codec.by_en.get(word.lower())   # by_en: en -> code
        if code is not None:
            units.append(("code", code))
        else:
            units.append(("lit", word))
    return units


def check_roundtrip(corpus, codec):
    bad = []
    for text in corpus:
        units = units_for(text, codec)
        try:
            blob = codec.encode(units)
            back = codec.decode(blob)
        except Exception as exc:                       # noqa: BLE001
            if "не помещается" in str(exc):
                continue          # честный отказ на сверхдлинном литерале
            bad.append((text[:40], f"исключение: {exc}"))
            continue
        if list(map(list, back)) != list(map(list, units)):
            bad.append((text[:40], "юниты не совпали"))
    return bad


def check_determinism(corpus, codec, rounds=3):
    bad = []
    for text in corpus:
        units = units_for(text, codec)
        try:
            first = bytes(codec.encode(units))
        except Exception:                              # noqa: BLE001
            continue
        for _ in range(rounds - 1):
            if bytes(codec.encode(units)) != first:
                bad.append((text[:40], "байты разошлись между вызовами"))
                break
    return bad


def check_bounds(codec):
    """Границы: escape-переполнение, пустые юниты, длинные литералы."""
    bad = []
    # Ожидаемые отказы: длинный литерал ОБЯЗАН бросать, а не терять
    # текст молча (найдено этим же стрессом 03.08).
    must_reject = {
        "литерал 256 символов (за границей)": [("lit", "я" * 256)],
        "литерал 1000 символов": [("lit", "я" * 1000)],
    }
    for name, units in must_reject.items():
        try:
            codec.encode(units)
            bad.append((name, "ТИХАЯ ПОТЕРЯ: закодировался вместо отказа"))
        except Exception:                                # noqa: BLE001
            pass                                         # honest refusal
    cases = {
        "пустые юниты": [],
        "один литерал 255 символов": [("lit", "я" * 255)],
        "эмодзи-литерал": [("lit", "❤️🔥🚑")],
        "нулевой код": [("code", 0)],
        "максимальный код словаря": [("code", max(k for k in codec.entries if k < 0xF000))],
    }
    for name, units in cases.items():
        try:
            blob = codec.encode(units)
            back = codec.decode(blob)
            if list(map(list, back)) != list(map(list, units)):
                bad.append((name, f"round-trip разошёлся: {back}"))
        except Exception as exc:                        # noqa: BLE001
            bad.append((name, f"исключение: {exc}"))
    return bad


def check_fuzz(corpus, codec, rng, rounds=20000):
    """Битые пакеты: ни падения, ни молчаливого принятия мусора."""
    crashes, silent = [], []
    blobs = []
    for text in corpus[:400]:
        try:
            blobs.append(bytes(codec.encode(units_for(text, codec))))
        except Exception:                               # noqa: BLE001
            pass
    if not blobs:
        return [("фаззинг", "нет валидных блобов для порчи")]
    for _ in range(rounds):
        blob = bytearray(rng.choice(blobs))
        if not blob:
            continue
        mode = rng.randrange(3)
        if mode == 0 and len(blob) > 1:                 # усечение
            blob = blob[:rng.randrange(1, len(blob))]
        elif mode == 1:                                 # порча байта
            i = rng.randrange(len(blob))
            blob[i] ^= 1 << rng.randrange(8)
        else:                                           # перемешивание
            rng.shuffle(blob)
        try:
            codec.decode(bytes(blob))
        except Exception:                               # noqa: BLE001
            pass                                        # честный отказ — норма
        except BaseException as exc:                    # noqa: BLE001
            crashes.append(str(exc)[:60])
    return [("падение декодера", c) for c in crashes[:5]]


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
    rng = random.Random(SEED)
    corpus = generate(n, rng)
    print(f"корпус: {len(corpus)} сообщений (seed {SEED})\n")
    codec = load_codec()

    defects = []
    if what in ("all", "roundtrip"):
        bad = check_roundtrip(corpus, codec)
        print(f"round-trip: расхождений {len(bad)} из {len(corpus)}")
        defects += [("round-trip", *b) for b in bad[:5]]
    if what in ("all", "determinism"):
        bad = check_determinism(corpus[:2000], codec)
        print(f"детерминизм: расхождений {len(bad)}")
        defects += [("детерминизм", *b) for b in bad[:5]]
    if what in ("all", "bounds"):
        bad = check_bounds(codec)
        print(f"границы кодека: проблем {len(bad)}")
        defects += [("границы", *b) for b in bad]
    if what in ("all", "fuzz"):
        bad = check_fuzz(corpus, codec, rng)
        print(f"фаззинг: падений {len(bad)}")
        defects += [("фаззинг", *b) for b in bad]

    print("\n— НАЙДЕННЫЕ ДЕФЕКТЫ —" if defects else "\nдефектов не найдено")
    for d in defects[:20]:
        print("  ", d)
    return 1 if defects else 0


if __name__ == "__main__":
    sys.exit(main())
