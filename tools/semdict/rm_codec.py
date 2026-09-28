# -*- coding: utf-8 -*-
"""rm_codec — настоящий битовый кодек словаря R+M (не оценка, а транспорт).

Поток: [varint: число единиц][битстрим канонического Хаффмана + escape-нагрузки]

Единица (unit):
  ("code", dict_code)          — смысловой код словаря
  ("num", int)                 — esc_number + varint(LEB128)
  ("lit", "text")              — esc_literal + len(1Б) + utf8
  ("name", "Mark")             — esc_name    + len(1Б) + utf8

Детерминизм: канонические коды Хаффмана строятся ТОЛЬКО из поля bits словаря
(sort by (bits, dict_code)) — одинаково на любом железе, любом языке реализации.
Swift-порт обязан сходиться с rm_codec_testvectors.json побайтово.
"""
import json
import re

class Codec:
    def __init__(self, dict_path="rm_dict_core_v0.json"):
        d = json.load(open(dict_path, encoding="utf-8"))
        self.version = d["version"]
        self.entries = {e["code"]: e for e in d["entries"]}
        # канонический Хаффман из длин
        order = sorted(d["entries"], key=lambda e: (e["bits"], e["code"]))
        canon, prev_len = 0, 0
        self.enc = {}                       # dict_code -> (bits, value)
        self.dec = {}                       # (bits, value) -> dict_code
        for e in order:
            canon <<= (e["bits"] - prev_len)
            prev_len = e["bits"]
            self.enc[e["code"]] = (e["bits"], canon)
            self.dec[(e["bits"], canon)] = e["code"]
            canon += 1
        self.by_en = {e["en"]: e["code"] for e in d["entries"]}
        self.ESC_NUM  = self.by_en["esc_number"]
        self.ESC_LIT  = self.by_en["esc_literal"]
        self.ESC_NAME = self.by_en["esc_name"]
        self.ESC_AMOUNT = self.by_en.get("esc_amount")
        self.ESC_TIME = self.by_en.get("esc_time")
        self.ESC_LOCAL = self.by_en.get("esc_local")
        self.ESC_EXT = self.by_en.get("esc_extension")
        # 3б (v1.2): второй канонический Хаффман — ПО СИМВОЛАМ литералов
        # (~35-40 бит на пятибуквенное слово против ~90 сырым UTF-8).
        # cp=0 — escape: следом 21 бит скаляра Unicode.
        import os as _os2
        _lc = json.load(open(_os2.path.join(
            _os2.path.dirname(_os2.path.abspath(__file__)),
            "litchars_v12.json"), encoding="utf-8"))["chars"]
        lengths = self._char_huffman_lengths(
            [(c["cp"], c["freq"]) for c in _lc])
        char_order = sorted(lengths.items(), key=lambda kv: (kv[1], kv[0]))
        canon = prev = 0
        self.char_enc, self.char_dec = {}, {}
        for cp, bits in char_order:
            canon <<= (bits - prev)
            prev = bits
            self.char_enc[cp] = (bits, canon)
            self.char_dec[(bits, canon)] = cp
            canon += 1

        # Фразы-ритуалы v1.1: таблица Хаффмана полная (Крафт=1.0) —
        # расширение через payload esc_local: [esc_local][id 1 байт],
        # id 0x00-0x7F общие фразы, 0x80-0xFF локальный словарь пары.
        import os as _os
        _pp = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                            "phrases_v11.json")
        _pj = json.load(open(_pp, encoding="utf-8"))
        self.phrases = {p["id"]: p for p in _pj["phrases"]}
        # Эмодзи v1.1: [esc_local][0x80][индекс] — таблица top-255,
        # отдельное пространство: рендер символом, никогда словом
        _ep = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                            "emoji_v11.json")
        self.emoji = json.load(open(_ep, encoding="utf-8"))["emoji"]
        self.emoji_index = {e: i for i, e in enumerate(self.emoji)}
        # Байт-отпечаток таблицы Хаффмана (FNV-1a 32 по (bits, code) в
        # каноническом порядке): летит первым байтом семантического
        # payload — приёмник с другой таблицей узнаёт об этом честно,
        # а не декодирует мусор. Совместимость версий (п.5, 28.07).
        # 03.08: версия словаря входит в отпечаток — измеренная
        # коллизия v1.2.0/v1.3.0 давала один байт 0xEE при разных
        # таблицах (см. RMCodec.swift, тот же комментарий).
        h = 2166136261
        for b in f"v{self.version};".encode():
            h = ((h ^ b) * 16777619) & 0xFFFFFFFF
        for e in order:
            for b in f"{e['code']}:{e['bits']};".encode():
                h = ((h ^ b) * 16777619) & 0xFFFFFFFF
        # 03.08 (решение владельца, вечер): в отпечаток входят и
        # канонические длины litchars. Раньше litchars жили вне
        # отпечатка провода: при совпадающем словаре и разных litchars
        # литералы декодировались МОЛЧА НЕВЕРНО — тот же класс, что
        # коллизия однобайтового отпечатка. Порядок строк — возрастание
        # cp (нормативно: docs/rm_wire_bitspec.md §4).
        for b in b"litchars;":
            h = ((h ^ b) * 16777619) & 0xFFFFFFFF
        for cp, bits in sorted((cp, bv[0])
                               for cp, bv in self.char_enc.items()):
            for b in f"{cp}:{bits};".encode():
                h = ((h ^ b) * 16777619) & 0xFFFFFFFF
        # 4 байта (решение владельца 03.08): один байт дал коллизию
        # v1.2.0/v1.3.0 на 0xEE, цена ошибки — молчаливое неверное
        # декодирование. Зеркало RMCodec.swift.
        self.table_hash = h & 0xFFFFFFFF

    @staticmethod
    def _char_huffman_lengths(items):
        import heapq as _hq
        from collections import defaultdict as _dd
        heap = [(f, i, [k]) for i, (k, f) in enumerate(items)]
        _hq.heapify(heap)
        depth = _dd(int)
        nxt = len(heap)
        while len(heap) > 1:
            f1, _, k1 = _hq.heappop(heap)
            f2, _, k2 = _hq.heappop(heap)
            for k in k1 + k2:
                depth[k] += 1
            _hq.heappush(heap, (f1 + f2, nxt, k1 + k2))
            nxt += 1
        return dict(depth)

    def _encode_lit_bits(self, w, text):
        """Литерал Хаффманом символов: [len симв. 1Б][битстрим].

        Длина литерала — ОДИН байт, поэтому больше 255 скаляров не
        влезает. Раньше лишнее молча обрезалось: сообщение уходило
        короче, чем написал человек, и никто об этом не узнавал
        (найдено синтетическим стрессом 03.08). Тихая потеря запрещена
        — бросаем, вызывающий откатится в текст.
        """
        if len(text) > 255:
            raise ValueError(
                f"литерал длиной {len(text)} символов не помещается "
                f"в один байт длины (максимум 255) — отправляем текстом")
        w.bytes_aligned(bytes([len(text)]))
        for ch in text:
            cp = ord(ch)
            if cp in self.char_enc:
                bits, v = self.char_enc[cp]
                w.bits(v, bits)
            else:
                bits, v = self.char_enc[0]
                w.bits(v, bits)
                w.bits(cp, 21)

    def _decode_lit_bits(self, rd):
        n = rd.bytes_aligned(1)[0]
        out = []
        for _ in range(n):
            bits, v = 0, 0
            while True:
                v = (v << 1) | rd.bits(1)
                bits += 1
                if (bits, v) in self.char_dec:
                    cp = self.char_dec[(bits, v)]
                    break
                if bits > 24:
                    raise ValueError("битый литерал-поток")
            out.append(chr(rd.bits(21)) if cp == 0 else chr(cp))
        return "".join(out)


    # --- провод: [table_hash][units-блоб] -------------------------------
    def wire_blob(self, blob):
        return self.table_hash.to_bytes(4, "big") + blob

    def unwrap_wire(self, data):
        """units-блоб или ValueError при несовпадении таблиц."""
        if len(data) < 4 or int.from_bytes(data[:4], "big") != self.table_hash:
            got = int.from_bytes(data[:4], "big") if len(data) >= 4 else 0
            raise ValueError("словарь другой версии "
                             f"(таблица 0x{got:08x} != 0x{self.table_hash:08x})")
        return bytes(data[4:])

    # Полная таблица валют ISO 4217 alpha-3, АЛФАВИТНЫЙ порядок.
    # ЗАМОРОЖЕНА с v1: индекс байта летит по проводу, менять и вставлять
    # нельзя; новые валюты — только в хвост. Индекс 255 зарезервирован:
    # «валюта литералом» — [255][3 байта ASCII alpha-3][varint].
    CURRENCIES = [
        "AED","AFN","ALL","AMD","ANG","AOA","ARS","AUD","AWG","AZN",
        "BAM","BBD","BDT","BGN","BHD","BIF","BMD","BND","BOB","BRL",
        "BSD","BTN","BWP","BYN","BZD","CAD","CDF","CHF","CLP","CNY",
        "COP","CRC","CUP","CVE","CZK","DJF","DKK","DOP","DZD","EGP",
        "ERN","ETB","EUR","FJD","FKP","GBP","GEL","GHS","GIP","GMD",
        "GNF","GTQ","GYD","HKD","HNL","HTG","HUF","IDR","ILS","INR",
        "IQD","IRR","ISK","JMD","JOD","JPY","KES","KGS","KHR","KMF",
        "KPW","KRW","KWD","KYD","KZT","LAK","LBP","LKR","LRD","LSL",
        "LYD","MAD","MDL","MGA","MKD","MMK","MNT","MOP","MRU","MUR",
        "MVR","MWK","MXN","MYR","MZN","NAD","NGN","NIO","NOK","NPR",
        "NZD","OMR","PAB","PEN","PGK","PHP","PKR","PLN","PYG","QAR",
        "RON","RSD","RUB","RWF","SAR","SBD","SCR","SDG","SEK","SGD",
        "SHP","SLE","SOS","SRD","SSP","STN","SVC","SYP","SZL","THB",
        "TJS","TMT","TND","TOP","TRY","TTD","TWD","TZS","UAH","UGX",
        "USD","UYU","UZS","VES","VND","VUV","WST","XAF","XCD","XOF",
        "XPF","YER","ZAR","ZMW","ZWG",
    ]
    CURRENCY_RAW = 255       # резерв: валюта литералом (3 байта ASCII)
    # Человеческие имена — только у ходовых; остальные рендерятся
    # ISO-кодом («200 MAD») — это честно и однозначно.
    CURRENCY_RU = {"USD": "долларов", "EUR": "евро", "RUB": "рублей",
                   "VND": "донгов", "IDR": "рупий", "AED": "дирхамов",
                   "THB": "батов", "GBP": "фунтов", "INR": "рупий (инд.)",
                   "CNY": "юаней", "JPY": "иен", "KZT": "тенге",
                   "TRY": "лир", "UAH": "гривен"}
    CURRENCY_EN = {"USD": "dollars", "EUR": "euro", "RUB": "rubles",
                   "VND": "dong", "IDR": "rupiah", "AED": "dirhams",
                   "THB": "baht", "GBP": "pounds", "INR": "rupees",
                   "CNY": "yuan", "JPY": "yen", "KZT": "tenge",
                   "TRY": "lira", "UAH": "hryvnia"}
    # слова пивота -> ISO (матчер склеивает «число + валюта» в amount)
    CURRENCY_WORDS = {
        "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD",
        "euro": "EUR", "euros": "EUR",
        "ruble": "RUB", "rubles": "RUB", "rouble": "RUB", "roubles": "RUB",
        "rur": "RUB",
        "dong": "VND", "dongs": "VND",
        "rupiah": "IDR", "rupiahs": "IDR",
        "dirham": "AED", "dirhams": "AED",
        "baht": "THB", "bahts": "THB",
    }

    # ---------------------------------------------------------------- биты
    class _W:
        def __init__(self): self.buf, self.acc, self.n = bytearray(), 0, 0
        def bits(self, value, width):
            self.acc = (self.acc << width) | (value & ((1 << width) - 1))
            self.n += width
            while self.n >= 8:
                self.n -= 8
                self.buf.append((self.acc >> self.n) & 0xFF)
        def bytes_aligned(self, data):      # выравнивание перед байтовой нагрузкой
            if self.n: self.bits(0, 8 - self.n)
            self.buf.extend(data)
        def done(self):
            if self.n: self.bits(0, 8 - self.n)
            return bytes(self.buf)

    class _R:
        def __init__(self, data): self.d, self.pos = data, 0   # pos в битах
        def bits(self, width):
            v = 0
            for _ in range(width):
                byte = self.d[self.pos >> 3]
                v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
                self.pos += 1
            return v
        def bytes_aligned(self, n):
            if self.pos & 7: self.pos = (self.pos + 7) & ~7
            start = self.pos >> 3
            self.pos += n * 8
            return self.d[start:start + n]

    @staticmethod
    def _varint(n):
        out = bytearray()
        while True:
            b = n & 0x7F; n >>= 7
            out.append(b | (0x80 if n else 0))
            if not n: return bytes(out)

    @staticmethod
    def _read_varint(rd):
        n = shift = 0
        while True:
            b = rd.bytes_aligned(1)[0]
            n |= (b & 0x7F) << shift
            if not (b & 0x80): return n
            shift += 7

    # ---------------------------------------------------------------- API
    def encode(self, units):
        w = self._W()
        for kind, val in units:
            if kind == "code":
                bits, v = self.enc[val]; w.bits(v, bits)
            elif kind == "num":
                bits, v = self.enc[self.ESC_NUM]; w.bits(v, bits)
                w.bytes_aligned(self._varint(val))
            elif kind == "amount":
                n, iso = val
                bits, v = self.enc[self.ESC_AMOUNT]; w.bits(v, bits)
                if iso in self.CURRENCIES:
                    payload = bytes([self.CURRENCIES.index(iso)])
                else:
                    # резерв 255: валюта литералом (ровно 3 байта ASCII)
                    payload = bytes([self.CURRENCY_RAW]) \
                        + iso.upper().encode("ascii")[:3].ljust(3, b"?")
                w.bytes_aligned(payload + self._varint(n))
            elif kind == "time":
                # минуты суток 0-1439 (varint 1-2 байта)
                bits, v = self.enc[self.ESC_TIME]; w.bits(v, bits)
                w.bytes_aligned(self._varint(val))
            elif kind == "phrase":
                # Валидные id фраз — ТОЛЬКО 0x00–0x7F: тег 0x80 занят
                # маркером эмодзи, и phrase(128) кодировался в байты
                # эмодзи с рассинхроном остатка потока (тихая порча,
                # аудит пределов 03.08). Спека: rm_wire_bitspec.md §3.
                if not 0 <= val <= 127:
                    raise ValueError(
                        f"индекс фразы {val} вне 0..127 (0x80 — эмодзи)")
                bits, v = self.enc[self.ESC_LOCAL]; w.bits(v, bits)
                w.bytes_aligned(bytes([val]))
            elif kind == "emoji":
                index = self.emoji_index[val]
                if index > 255:
                    raise ValueError(
                        f"индекс эмодзи {index} не влезает в байт — "
                        "таблица выросла за 256, нужен новый escape")
                bits, v = self.enc[self.ESC_LOCAL]; w.bits(v, bits)
                w.bytes_aligned(bytes([0x80, index]))
            elif kind in ("lit", "name"):
                esc = self.ESC_LIT if kind == "lit" else self.ESC_NAME
                bits, v = self.enc[esc]; w.bits(v, bits)
                self._encode_lit_bits(w, val)      # v1.2: Хаффман символов
            elif kind == "ext":
                # резерв будущих кодов: [esc_extension][12 бит индекса]
                # Раньше 4096 молча кодировался как 0 (битовая маска без
                # проверки; Swift честно бросал) — аудит пределов 03.08.
                # 4095 зарезервирован под 16-битный каскад (реестр
                # ext_registry.json, решение владельца 03.08): кодировать
                # нельзя, пока каскада нет; декод терпим — заглушка.
                if not 0 <= val <= 4094:
                    raise ValueError(
                        f"индекс расширения {val} вне 0..4094 "
                        f"(4095 — резерв каскада)")
                bits, v = self.enc[self.ESC_EXT]; w.bits(v, bits)
                w.bits(val, 12)
            else:
                raise ValueError(kind)
        return self._varint(len(units)) + w.done()

    def decode(self, data):
        rd = self._R(data)
        n = self._read_varint(rd)
        units = []
        for _ in range(n):
            bits, v = 0, 0
            while True:                       # канонический Хаффман: наращиваем
                v = (v << 1) | rd.bits(1); bits += 1
                if (bits, v) in self.dec:
                    code = self.dec[(bits, v)]; break
                if bits > 24: raise ValueError("bad stream")
            if code == self.ESC_NUM:
                units.append(("num", self._read_varint(rd)))
            elif code == self.ESC_AMOUNT:
                index = rd.bytes_aligned(1)[0]
                if index == self.CURRENCY_RAW:
                    iso = rd.bytes_aligned(3).decode("ascii")
                else:
                    iso = self.CURRENCIES[index]
                units.append(("amount", (self._read_varint(rd), iso)))
            elif code == self.ESC_TIME:
                units.append(("time", self._read_varint(rd)))
            elif code == self.ESC_LOCAL:
                tag = rd.bytes_aligned(1)[0]
                if tag == 0x80:
                    units.append(("emoji",
                                  self.emoji[rd.bytes_aligned(1)[0]]))
                else:
                    units.append(("phrase", tag))
            elif code in (self.ESC_LIT, self.ESC_NAME):
                s = self._decode_lit_bits(rd)
                units.append(("lit" if code == self.ESC_LIT else "name", s))
            elif code == self.ESC_EXT:
                units.append(("ext", rd.bits(12)))
            else:
                units.append(("code", code))
        return units

    # ---------------------------------------------------------------- разворот
    RU_DROP = {"the","a","an","of","is","are","am","was","were","be","been",
               "will","would","do","does","did","to","it","this is","that is",
               "it is","there is","of the"}
    @staticmethod
    def first_variant(ru):
        # варианты слова через «/» («ушёл/налево», «иди/еду домой») —
        # рендер берёт первый вариант каждого такого слова
        return " ".join(t.split("/")[0] if "/" in t else t
                        for t in ru.split(" "))

    # Пунктуация v1.1: запятые — ноль бит, правило рендера,
    # ЯЗЫКОВАЯ таблица (у каждого языка свои правила). Запятая ставится
    # перед словом из набора, если это не начало предложения.
    COMMA_BEFORE = {
        "ru": {"если", "но", "потому", "чтобы", "когда", "хотя", "иначе",
               "который", "которая"},
        "en": {"but", "because", "although", "otherwise", "which"},
    }
    _BOUNDARY_RU = {"sent_end": ".", "sent_question": "?",
                    "sent_exclaim": "!"}
    # display-подмены грамматики: ru-строки операторов — описания, в
    # ленте им место человеческое (слой отображения, словарь не трогаем)
    _OP_DISPLAY = {"ru": {"op_emphasis": "точно"},
                   "en": {"op_emphasis": "for sure"}}

    # Языковое правило рендера (как запятые, ноль бит): цепочка
    # [in][num N][hour/minute] — ОТНОСИТЕЛЬНОЕ время, по-русски
    # «через N …», не «в N …» (живой прогон 29.07: «выхожу через час»
    # рендерился «в 1 час» и паттерн метки времени не срабатывал).
    _REL_TIME_UNITS = {"hour", "hours", "minute", "minutes"}

    def _mark_relative_time(self, units, lang):
        if lang != "ru":
            return units
        out = list(units)
        for i in range(len(out) - 2):
            a, b, c = out[i], out[i + 1], out[i + 2]
            if (a[0] == "code" and self.entries[a[1]]["en"] == "in"
                    and b[0] == "num" and c[0] == "code"
                    and self.entries[c[1]]["en"] in self._REL_TIME_UNITS):
                out[i] = ("lit", "через")
        return out

    def render(self, units, lang="ru"):
        units = self._mark_relative_time(units, lang)
        out = []
        for kind, val in units:
            if kind == "code":
                e = self.entries[val]
                if e["en"] in self._BOUNDARY_RU:
                    # границы предложений — знаком в ЛЮБОМ языке
                    out.append(self._BOUNDARY_RU[e["en"]])
                    continue
                if e["en"] in self._OP_DISPLAY.get(lang, {}):
                    out.append(self._OP_DISPLAY[lang][e["en"]])
                    continue
                if lang == "ru" and e["en"] in self.RU_DROP:
                    continue
                s = e.get(lang)
                out.append(self.first_variant(s) if s else e["en"])
            elif kind == "num":
                out.append(str(val))
            elif kind == "amount":
                n, iso = val
                names = self.CURRENCY_RU if lang == "ru" else self.CURRENCY_EN
                out.append(f"{n} {names.get(iso, iso)}")
            elif kind == "time":
                out.append(f"{val // 60:02d}:{val % 60:02d}")
            elif kind == "phrase":
                p = self.phrases.get(val)
                out.append((p[lang] if p and lang in p else
                            p["en"] if p else f"phrase#{val}"))
            elif kind == "emoji":
                out.append(val)     # символом, никогда словом
            elif kind == "ext":
                # будущий код, неизвестный этой версии: честный
                # фоллбэк-литерал по признаку, не мусор
                out.append(f"⟨расширение {val}⟩")
            elif kind == "name":
                # имя всегда с заглавной — независимо от регистра в блобе
                # (ферма 28.07: имена доходили строчными)
                out.append(val[:1].upper() + val[1:])
            else:
                out.append(val)
        text = " ".join(out)
        # терминальные знаки клеятся к предыдущему слову
        text = re.sub(r"\s+([.?!])", r"\1", text)
        # запятые: перед словами из языковой таблицы (не в начале
        # предложения); заглавная — после терминального знака
        comma = self.COMMA_BEFORE.get(lang, set())
        words = text.split(" ")
        rebuilt = []
        for w in words:
            bare = w.lower().strip(".?!,")
            if (rebuilt and bare in comma
                    and rebuilt[-1][-1:] not in (".", "?", "!", ",")):
                rebuilt[-1] = rebuilt[-1] + ","
            rebuilt.append(w)
        text = " ".join(rebuilt)
        parts = re.split(r"([.?!]\s*)", text)
        text = "".join(pc[:1].upper() + pc[1:] if pi % 2 == 0 else pc
                       for pi, pc in enumerate(parts))
        return text[:1].upper() + text[1:] if text else text


def apply_sent_time(text, sent_at_minutes, lang="ru", tz_offset_minutes=0):
    """Ф5: относительное время — от метки отправки (зеркало Swift
    applySentTime). tz_offset_minutes — смещение зоны отображения."""
    if not sent_at_minutes or "(к " in text:
        return text          # идемпотентность: метку не дублируем
    def clock(offset_min):
        total = (sent_at_minutes + offset_min + tz_offset_minutes) % 1440
        return f"{total // 60 % 24:02d}:{total % 60:02d}"
    pats = ([(r"in (\d+) hours?", 60), (r"in (\d+) minutes?", 1)]
            if lang == "en" else
            [(r"через (\d+) час[а-яё]*", 60), (r"через (\d+) минут[а-яё]*", 1)])
    for pat, unit in pats:
        def repl(m):
            return m.group(0) + " (к " + clock(int(m.group(1)) * unit) + ")"
        text = re.sub(pat, repl, text)
    if lang == "ru" and "(к " not in text:
        text = re.sub(r"через час(?!\S)",
                      lambda m: m.group(0) + " (к " + clock(60) + ")", text)
    return text


if __name__ == "__main__":
    c = Codec()
    vectors = [
        [("code", c.by_en["all good"]), ("code", c.by_en["do not worry"])],
        [("code", c.by_en["be there soon"]), ("code", c.by_en["in"]),
         ("num", 20), ("code", c.by_en["minutes"])],
        [("code", c.by_en["sos_active"]), ("code", c.by_en["severity_critical"]),
         ("num", 3), ("code", c.by_en["people"]),
         ("code", c.by_en["injury_bleeding"]), ("code", c.by_en["need_bandages"]),
         ("code", c.by_en["need_boat"])],
        [("code", c.by_en["i"]), ("code", c.by_en["at the pier"]),
         ("name", "Mark"), ("lit", "paxil")],
        [("num", 0), ("num", 127), ("num", 128), ("num", 100000)],
        [("code", c.by_en["take"]), ("amount", (200, "AED")),
         ("code", c.by_en["cash"]), ("amount", (1500000, "VND"))],
        [("time", 440), ("time", 1170), ("num", 20),
         ("code", c.by_en["percent"]), ("code", c.by_en["battery"])],
        # полная валютная таблица: экзотика индексом, не-ISO — литералом
        [("amount", (50, "MAD")), ("amount", (7, "XXX"))],
        # v1.1: фразы esc_local + эмодзи отдельным пространством
        [("phrase", 1), ("emoji", "👍"), ("phrase", 4), ("emoji", "❤️")],
        # v1.2: дешёвый литерал (Хаффман символов) + escape-расширение
        [("lit", "casablanca"), ("name", "Марина"), ("ext", 7)],
    ]
    tv = []
    for u in vectors:
        blob = c.encode(u)
        assert c.decode(blob) == u, f"roundtrip fail: {u}"
        tv.append(dict(units=u, hex=blob.hex(), bytes=len(blob),
                       ru=c.render(u)))
        print(f"{len(blob):>3}Б  {blob.hex():<44}  {c.render(u)}")
    json.dump(dict(dict_version=c.version, vectors=tv),
              open("rm_codec_testvectors.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("тест-векторы записаны: rm_codec_testvectors.json")
