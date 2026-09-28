# -*- coding: utf-8 -*-
"""
test_envelope.py — тесты кодека R+M Envelope v0 по разделу 8 спеки.

Главное здесь — тест-векторы ТВ-1 и ТВ-2: они обязаны совпадать
с документом ПОБАЙТОВО. Когда появится Swift-реализация, она должна
пройти ровно эти же векторы — так мы узнаем, что два кодека совместимы.

Запуск:  python3 sim/test_envelope.py
Подробно: python3 sim/test_envelope.py -v
"""

import json
import pathlib
import random
import unittest

from envelope import (
    Ack, Beacon, Location, Reassembler, SOS, TextFragment, TextMessage,
    CODEC_STORE, CODEC_ZLIB, MAX_FRAGMENTS,
    decode_packet, encode_coarse_coords, decode_coarse_coords,
    encode_fine_coords, decode_fine_coords,
    decode_needs, encode_needs, encode_text,
)
from transport_sim import LoRaChannel

# Общий файл тест-векторов: его же будет проходить Swift-реализация
ФАЙЛ_ВЕКТОРОВ = (pathlib.Path(__file__).resolve().parent.parent
                 / "tests" / "envelope_test_vectors.json")


class TestТестВекторы(unittest.TestCase):
    """ТВ-1, ТВ-2, ТВ-2б — побайтовое совпадение со спекой (§8)."""

    def test_тв1_минимальный_sos_кодирование(self):
        """ТВ-1: SOS без координат и хвоста -> ровно 12 байт из документа."""
        sos = SOS(msg_id=0x3BA7, severity=3, people_count=3, injury=1,
                  hops_left=3, needs={0, 3})
        ожидаемые = bytes.fromhex("11 00 A7 3B C3 13 FF FF FF FF 09 00".replace(" ", ""))
        self.assertEqual(sos.encode(), ожидаемые)

    def test_тв1_декодирование(self):
        """ТВ-1 в обратную сторону: из байтов документа — исходные поля."""
        данные = bytes.fromhex("1100A73BC313FFFFFFFF0900")
        sos = decode_packet(данные)
        self.assertIsInstance(sos, SOS)
        self.assertEqual(sos.msg_id, 0x3BA7)
        self.assertEqual(sos.severity, 3)          # critical
        self.assertEqual(sos.people_count, 3)
        self.assertEqual(sos.injury, 1)            # кровотечение
        self.assertEqual(sos.hops_left, 3)
        self.assertIsNone(sos.lat)                 # координат нет
        self.assertIsNone(sos.lon)
        self.assertEqual(sos.needs, {0, 3})        # бинты + лодка
        self.assertIsNone(sos.text_tail)

    def test_тв2_sos_с_грубыми_координатами(self):
        """ТВ-2: тот же SOS с координатами Бали -> байты из документа."""
        sos = SOS(msg_id=0x3BA7, severity=3, people_count=3, injury=1,
                  hops_left=3, needs={0, 3}, lat=8.71, lon=115.17)
        ожидаемые = bytes.fromhex("11 08 A7 3B C3 13 63 8C E5 D1 09 00".replace(" ", ""))
        self.assertEqual(sos.encode(), ожидаемые)

    def test_тв2_обратное_преобразование_грубых_координат(self):
        """ТВ-2: раскодированные грубые координаты — 8.7109 / 115.1687.

        Смещение около 100 и 145 метров — это цель, а не ошибка:
        «где-то здесь», а не «вот тут».
        """
        sos = decode_packet(bytes.fromhex("1108A73BC313638CE5D10900"))
        self.assertAlmostEqual(sos.lat, 8.7109, places=4)
        self.assertAlmostEqual(sos.lon, 115.1687, places=4)

    def test_тв2б_точные_координаты_кодирование(self):
        """ТВ-2б: точные координаты -> 36 63 8C / 0E E6 D1 (little-endian)."""
        self.assertEqual(encode_fine_coords(8.71, 115.17),
                         bytes.fromhex("36 63 8C 0E E6 D1".replace(" ", "")))

    def test_тв2б_точные_координаты_без_потерь(self):
        """ТВ-2б: обратное преобразование даёт ровно 8.71000 / 115.17000."""
        lat, lon = decode_fine_coords(bytes.fromhex("36638C0EE6D1"))
        self.assertAlmostEqual(lat, 8.71, places=5)
        self.assertAlmostEqual(lon, 115.17, places=5)


class TestТВ3Каноничность(unittest.TestCase):
    """ТВ-3: одни данные — всегда одни и те же байты (§8, принцип П6)."""

    def test_разный_порядок_заполнения_полей(self):
        """Одна структура, собранная двумя способами, — байт в байт одинакова."""
        # Способ 1: всё сразу в конструкторе, needs в одном порядке
        первый = SOS(msg_id=0x3BA7, severity=3, people_count=3, injury=1,
                     hops_left=3, needs={0, 3}, lat=8.71, lon=115.17)

        # Способ 2: поля заполняются после создания, needs в обратном порядке
        второй = SOS(msg_id=0x3BA7, severity=3, people_count=3, injury=1)
        второй.needs = set()
        второй.needs.add(3)
        второй.needs.add(0)
        второй.hops_left = 3
        второй.lon = 115.17
        второй.lat = 8.71

        self.assertEqual(первый.encode(), второй.encode())

    def test_повторное_кодирование_стабильно(self):
        """Один объект, закодированный дважды, даёт одинаковые байты."""
        sos = SOS(msg_id=0x1234, severity=2, people_count=5, injury=4,
                  needs={1, 5, 7}, lat=-8.65, lon=115.22)
        self.assertEqual(sos.encode(), sos.encode())

    def test_декодировать_и_закодировать_обратно(self):
        """decode -> encode возвращает исходные байты без изменений."""
        исходные = bytes.fromhex("1108A73BC313638CE5D10900")
        self.assertEqual(decode_packet(исходные).encode(), исходные)


class TestТВ4Фрагментация(unittest.TestCase):
    """ТВ-4: резка, перемешивание, потеря, дослал — собралось (§8)."""

    def _текст_на_500_байт(self):
        # Латинские буквы: 1 байт на символ, ровно 500 байт нагрузки
        return "".join(chr(ord("A") + i % 26) for i in range(500))

    def test_сценарий_из_спеки(self):
        """Перемешали, потеряли один фрагмент — не собирается; дослали — собирается."""
        текст = self._текст_на_500_байт()
        пакеты = encode_text(0x5150, текст)
        self.assertGreaterEqual(len(пакеты), 3)  # точно фрагментировалось

        фрагменты = [decode_packet(p) for p in пакеты]
        for f in фрагменты:
            self.assertIsInstance(f, TextFragment)

        # Перемешиваем порядок (фиксированный seed — прогон воспроизводим)
        random.Random(42).shuffle(фрагменты)

        # «Теряем» один фрагмент
        потерянный = фрагменты.pop(0)

        сборщик = Reassembler()
        результаты = [сборщик.add(f) for f in фрагменты]

        # Без одного фрагмента сообщение собраться НЕ должно
        self.assertTrue(all(r is None for r in результаты))
        self.assertEqual(сборщик.pending_count(), 1)

        # Дослали потерянный — собралось, текст совпал байт в байт
        self.assertEqual(сборщик.add(потерянный), текст)
        self.assertEqual(сборщик.pending_count(), 0)

    def test_дубликат_не_ломает_сборку(self):
        """Дубликаты фрагментов отбрасываются и не мешают сборке."""
        текст = self._текст_на_500_байт()
        фрагменты = [decode_packet(p) for p in encode_text(0x5151, текст)]

        сборщик = Reassembler()
        # Каждый фрагмент подаём ДВАЖДЫ
        результат = None
        for f in фрагменты:
            for _ in range(2):
                r = сборщик.add(f)
                if r is not None:
                    результат = r
        self.assertEqual(результат, текст)

    def test_слишком_много_фрагментов(self):
        """Текст, не влезающий в 16 фрагментов, — ошибка, а не тихая обрезка."""
        огромный = "х" * 4000   # кириллица: 2 байта на символ = 8000 байт
        with self.assertRaises(ValueError):
            encode_text(0x5152, огромный)
        # А ровно на границе — работает (16 фрагментов это максимум)
        максимум = "a" * ((200 - 6) * MAX_FRAGMENTS - 1)
        self.assertEqual(len(encode_text(0x5153, максимум[:-4])), MAX_FRAGMENTS)

    def test_таймаут_недособранного(self):
        """Неполное сообщение хранится 10 минут, потом отбрасывается (§7)."""
        фрагменты = [decode_packet(p) for p in encode_text(0x5154, self._текст_на_500_байт())]

        сборщик = Reassembler()
        сборщик.add(фрагменты[0], now=0.0)          # первый пришёл сразу
        self.assertEqual(сборщик.pending_count(), 1)

        # Остальные пришли через 700 секунд — старый кусок уже выброшен,
        # поэтому сообщение всё равно неполное
        результаты = [сборщик.add(f, now=700.0) for f in фрагменты[1:]]
        self.assertTrue(all(r is None for r in результаты))

        # Досылаем первый ещё раз — теперь всё собирается
        self.assertEqual(сборщик.add(фрагменты[0], now=701.0),
                         self._текст_на_500_байт())

    def test_короткий_текст_без_фрагментации(self):
        """Короткий текст идёт одним пакетом, без блока фрагментации."""
        пакеты = encode_text(0x5155, "Вышли на тропу, всё в порядке")
        self.assertEqual(len(пакеты), 1)
        сообщение = decode_packet(пакеты[0])
        self.assertIsInstance(сообщение, TextMessage)
        self.assertEqual(сообщение.text, "Вышли на тропу, всё в порядке")


class TestХвостИКодеки(unittest.TestCase):
    """Текстовый хвост SOS и сменные кодеки сжатия (§6)."""

    def test_хвост_туда_и_обратно(self):
        """Короткий хвост доезжает и раскодируется в тот же текст."""
        sos = SOS(msg_id=0x0001, severity=2, people_count=1, injury=2,
                  needs={5}, text_tail="нога зажата камнем")
        got = decode_packet(sos.encode())
        self.assertEqual(got.text_tail, "нога зажата камнем")

    def test_слишком_длинный_хвост_отбрасывается_целиком(self):
        """SOS не фрагментируется (П5): не влез хвост — он отброшен, пакет ≤ 200."""
        sos = SOS(msg_id=0x0002, severity=3, people_count=2, injury=6,
                  needs={5, 7}, text_tail="очень длинное описание " * 30)
        байты = sos.encode()
        self.assertLessEqual(len(байты), 200)
        self.assertEqual(len(байты), 12)            # остался только сам SOS
        self.assertIsNone(decode_packet(байты).text_tail)

    def test_кодек_zlib(self):
        """Хвост с кодеком zlib сжимается и разжимается без потерь."""
        текст = "вода вода вода вода вода нужна вода " * 3
        sos = SOS(msg_id=0x0003, severity=1, people_count=4, injury=0,
                  needs={1}, text_tail=текст, tail_codec=CODEC_ZLIB)
        байты = sos.encode()
        self.assertLessEqual(len(байты), 200)       # zlib ужал повторы
        got = decode_packet(байты)
        self.assertEqual(got.text_tail, текст)
        self.assertEqual(got.tail_codec, CODEC_ZLIB)

    def test_кодеки_в_text(self):
        """TEXT с кодеком zlib проходит туда и обратно."""
        текст = "то же слово то же слово то же слово " * 10
        пакеты = encode_text(0x0004, текст, codec=CODEC_ZLIB)
        self.assertEqual(len(пакеты), 1)            # сжатие уложило в один пакет
        self.assertEqual(decode_packet(пакеты[0]).text, текст)


class TestОстальныеКлассы(unittest.TestCase):
    """ACK (§5а), BEACON (§5б), LOCATION, маска needs."""

    def test_ack_туда_и_обратно(self):
        """ACK: 6 байт, несёт msg_id подтверждаемого сообщения."""
        байты = Ack(msg_id=0x1111, ack_msg_id=0x3BA7).encode()
        self.assertEqual(len(байты), 6)
        got = decode_packet(байты)
        self.assertEqual(got.msg_id, 0x1111)
        self.assertEqual(got.ack_msg_id, 0x3BA7)

    def test_beacon_без_координат(self):
        """BEACON: 7 байт, статус и число откликнувшихся упакованы в 1 байт."""
        маячок = Beacon(msg_id=0x2222, sos_msg_id=0x3BA7, status=1, responders=2)
        байты = маячок.encode()
        self.assertEqual(len(байты), 7)
        got = decode_packet(байты)
        self.assertEqual(got.sos_msg_id, 0x3BA7)
        self.assertEqual(got.status, 1)             # помощь идёт
        self.assertEqual(got.responders, 2)
        self.assertIsNone(got.lat)

    def test_beacon_с_координатами(self):
        """BEACON с флагом 3: добавляются грубые координаты (человек переместился)."""
        маячок = Beacon(msg_id=0x2223, sos_msg_id=0x3BA7, status=0,
                        responders=63, lat=8.71, lon=115.17)
        байты = маячок.encode()
        self.assertEqual(len(байты), 11)
        got = decode_packet(байты)
        self.assertEqual(got.responders, 63)        # «много»
        self.assertAlmostEqual(got.lat, 8.7109, places=4)
        self.assertAlmostEqual(got.lon, 115.1687, places=4)

    def test_beacon_проверка_диапазонов(self):
        """Статус больше 3 или откликнувшихся больше 63 — ошибка сразу."""
        with self.assertRaises(ValueError):
            Beacon(msg_id=1, sos_msg_id=2, status=4, responders=0).encode()
        with self.assertRaises(ValueError):
            Beacon(msg_id=1, sos_msg_id=2, status=0, responders=64).encode()

    def test_location_туда_и_обратно(self):
        """LOCATION: точные координаты доезжают с точностью до 5 знака."""
        байты = Location(msg_id=0x3333, lat=-8.409518, lon=115.188919,
                         want_ack=True).encode()
        self.assertEqual(len(байты), 10)
        got = decode_packet(байты)
        self.assertAlmostEqual(got.lat, -8.409518, places=5)
        self.assertAlmostEqual(got.lon, 115.188919, places=5)
        self.assertTrue(got.want_ack)

    def test_location_без_фикса(self):
        """LOCATION без GPS: поля-единицы, флага координат нет."""
        байты = Location(msg_id=0x3334).encode()
        self.assertEqual(байты[4:10], b"\xFF" * 6)
        self.assertIsNone(decode_packet(байты).lat)

    def test_маска_needs_все_биты(self):
        """Все 16 позиций потребностей проходят туда и обратно."""
        все = set(range(16))
        self.assertEqual(decode_needs(encode_needs(все)), все)
        self.assertEqual(encode_needs(все), b"\xFF\xFF")
        self.assertEqual(decode_needs(b"\x00\x00"), set())

    def test_неизвестная_версия_отклоняется(self):
        """Версии 0-1 принимаются (совместимость v1), 2+ — ошибка."""
        битый = bytes.fromhex("2100A73BC313FFFFFFFF0900")  # версия 2
        with self.assertRaises(ValueError):
            decode_packet(битый)
        # версия 0 по-прежнему читается (старый отправитель)
        старый = bytes.fromhex("0100A73BC313FFFFFFFF0900")
        self.assertEqual(decode_packet(старый).msg_id, 0x3BA7)

    def test_зарезервированные_флаги_отклоняются(self):
        """Единицы в битах 4-7 флагов — ошибка формата."""
        битый = bytes.fromhex("1180A73BC313FFFFFFFF0900")  # бит 7 установлен
        with self.assertRaises(ValueError):
            decode_packet(битый)


class TestСимуляторКанала(unittest.TestCase):
    """transport_sim: потери, дубликаты, лимит 200 байт, сквозной прогон."""

    def test_баланс_счётчиков(self):
        """Каждая копия пакета либо доставлена, либо потеряна — ничего не исчезает."""
        канал = LoRaChannel(loss=0.3, duplicate=0.2, seed=7)
        for i in range(100):
            канал.send(bytes([i % 256]) * 10)
        дошло = канал.deliver_all()

        s = канал.stats
        self.assertEqual(s["sent"], 100)
        self.assertEqual(s["delivered"], len(дошло))
        # копий запущено: 100 (оригиналы) + дубликаты; каждая либо дошла, либо потерялась
        self.assertEqual(s["delivered"] + s["lost"], 100 + s["duplicated"])
        self.assertGreater(s["lost"], 0)            # при 30% потерь что-то да пропало
        self.assertGreater(s["duplicated"], 0)

    def test_лимит_размера_пакета(self):
        """Пакет больше 200 байт в эфир не уходит."""
        канал = LoRaChannel(seed=1)
        self.assertFalse(канал.send(b"\x00" * 201))
        self.assertTrue(канал.send(b"\x00" * 200))
        self.assertEqual(канал.stats["oversize"], 1)
        self.assertEqual(len(канал.deliver_all()), 1)

    def test_перестановка_порядка(self):
        """Из-за случайных задержек порядок прибытия отличается от порядка отправки."""
        канал = LoRaChannel(loss=0.0, reorder=0.5, seed=3)
        отправлено = [bytes([i]) for i in range(30)]
        for p in отправлено:
            канал.send(p)
        дошло = канал.deliver_all()
        self.assertEqual(sorted(дошло), sorted(отправлено))  # ничего не потерялось
        self.assertNotEqual(дошло, отправлено)               # но порядок другой

    def test_сквозной_прогон_фрагментов_через_канал(self):
        """Длинный текст доезжает через канал с потерями за счёт повторов."""
        текст = ("Пакет за пакетом сквозь помехи, потери и дубликаты. " * 12)
        пакеты = encode_text(0x77A1, текст)
        self.assertGreater(len(пакеты), 1)          # точно фрагментировалось

        канал = LoRaChannel(loss=0.3, duplicate=0.1, reorder=0.2, seed=5)
        сборщик = Reassembler()

        результат = None
        for попытка in range(50):
            if результат is not None:
                break
            for p in пакеты:                        # шлём все фрагменты заново
                канал.send(p)
            for raw in канал.deliver_all():
                item = decode_packet(raw)
                r = сборщик.add(item, now=канал.now)
                if r is not None:
                    результат = r
                    break

        self.assertEqual(результат, текст)


class TestОбщиеТестВекторы(unittest.TestCase):
    """Векторы из tests/envelope_test_vectors.json.

    Этот же файл обязана пройти будущая Swift-реализация — побайтово.
    Если оба кодека проходят его целиком, они совместимы.
    """

    @classmethod
    def setUpClass(cls):
        with open(ФАЙЛ_ВЕКТОРОВ, encoding="utf-8") as f:
            cls.векторы = json.load(f)

    @staticmethod
    def _байты(hex_строка):
        """Шестнадцатеричная строка из файла (с пробелами) -> байты."""
        return bytes.fromhex(hex_строка.replace(" ", ""))

    @staticmethod
    def _закодировать(вектор):
        """Строит объект из полей вектора и возвращает его байты."""
        поля = вектор["fields"]
        клс = вектор["class"]
        mid = int(поля["msg_id_hex"], 16)
        if клс == "SOS":
            return SOS(msg_id=mid, severity=поля["severity"],
                       people_count=поля["people_count"], injury=поля["injury"],
                       hops_left=поля["hops_left"],
                       lat=поля.get("lat"), lon=поля.get("lon"),
                       needs=set(поля["needs"]),
                       text_tail=поля.get("text_tail"),
                       tail_codec=поля.get("tail_codec", CODEC_STORE)).encode()
        if клс == "BEACON":
            return Beacon(msg_id=mid, sos_msg_id=int(поля["sos_msg_id_hex"], 16),
                          status=поля["status"], responders=поля["responders"],
                          lat=поля.get("lat"), lon=поля.get("lon")).encode()
        if клс == "ACK":
            return Ack(msg_id=mid, ack_msg_id=int(поля["ack_msg_id_hex"], 16)).encode()
        if клс == "LOCATION":
            return Location(msg_id=mid, lat=поля.get("lat"), lon=поля.get("lon"),
                            want_ack=поля.get("want_ack", False)).encode()
        if клс == "TEXT":
            пакеты = encode_text(mid, поля["text"],
                                 codec=поля.get("codec", CODEC_STORE),
                                 want_ack=поля.get("want_ack", False))
            assert len(пакеты) == 1, "вектор TEXT должен помещаться в один пакет"
            return пакеты[0]
        raise AssertionError(f"неизвестный класс в векторе: {клс}")

    def test_кодирование_пакетов(self):
        """Каждый вектор кодируется ровно в байты из файла."""
        for в in self.векторы["packets"]:
            if в.get("direction") == "decode":
                continue  # у этого вектора проверяется только разбор
            with self.subTest(в["name"]):
                self.assertEqual(self._закодировать(в), self._байты(в["bytes_hex"]))

    def test_декодирование_пакетов(self):
        """Байты из файла разбираются, повторное кодирование даёт их же."""
        for в in self.векторы["packets"]:
            байты = self._байты(в["bytes_hex"])
            with self.subTest(в["name"]):
                объект = decode_packet(байты)
                if в.get("direction") == "decode":
                    # Фрагмент: отдельного кодера у него нет, сверяем поля
                    поля = в["fields"]
                    self.assertIsInstance(объект, TextFragment)
                    self.assertEqual(объект.msg_id, int(поля["msg_id_hex"], 16))
                    self.assertEqual(объект.index, поля["index"])
                    self.assertEqual(объект.total, поля["total"])
                    self.assertEqual(объект.chunk, bytes.fromhex(поля["chunk_hex"]))
                elif isinstance(объект, TextMessage):
                    повтор = encode_text(объект.msg_id, объект.text,
                                         codec=объект.codec,
                                         want_ack=объект.want_ack)[0]
                    self.assertEqual(повтор, байты)
                else:
                    self.assertEqual(объект.encode(), байты)

    def test_грубые_координаты(self):
        """Кодирование и разбор грубых координат по векторам из файла."""
        for в in self.векторы["coarse_coords"]:
            with self.subTest(в["name"]):
                self.assertEqual(encode_coarse_coords(в["lat"], в["lon"]),
                                 self._байты(в["bytes_hex"]))
                lat, lon = decode_coarse_coords(self._байты(в["bytes_hex"]))
                self.assertAlmostEqual(lat, в["decoded_lat"], delta=в["tolerance"])
                self.assertAlmostEqual(lon, в["decoded_lon"], delta=в["tolerance"])

    def test_точные_координаты(self):
        """Кодирование и разбор точных координат по векторам из файла."""
        for в in self.векторы["fine_coords"]:
            with self.subTest(в["name"]):
                self.assertEqual(encode_fine_coords(в["lat"], в["lon"]),
                                 self._байты(в["bytes_hex"]))
                lat, lon = decode_fine_coords(self._байты(в["bytes_hex"]))
                self.assertAlmostEqual(lat, в["decoded_lat"], delta=в["tolerance"])
                self.assertAlmostEqual(lon, в["decoded_lon"], delta=в["tolerance"])

    def test_маски_needs(self):
        """Маска потребностей по векторам из файла, туда и обратно."""
        for в in self.векторы["needs_masks"]:
            with self.subTest(в["name"]):
                self.assertEqual(encode_needs(set(в["needs"])), self._байты(в["bytes_hex"]))
                self.assertEqual(decode_needs(self._байты(в["bytes_hex"])), set(в["needs"]))


class TestРевизияB(unittest.TestCase):
    """Кодеки 5/7, тег Т1 и префикс рев B — по векторам из спеки шва.

    Вектора (tests/sealed_revb_vectors.json) посчитаны НЕЗАВИСИМЫМ
    генератором на сырых примитивах (sim/sealed_revb_vectors_gen.py)
    с ручными якорями — не выводом этого кода. Кодек 6 (session2) —
    зеркала рэтчета в python нет (как и у кодека 4), его вектора
    проходит Swift.
    """

    @classmethod
    def setUpClass(cls):
        путь = (pathlib.Path(__file__).resolve().parent.parent
                / "tests" / "sealed_revb_vectors.json")
        cls.вб = json.loads(путь.read_text(encoding="utf-8"))

    @staticmethod
    def _б(hex_str):
        return bytes.fromhex(hex_str)

    def test_тег_отправителя_т1(self):
        """HMAC(pairKey, "sender-tag"+epoch)[0..2] — байты из вектора."""
        from e2e_seal import sender_tag
        for в in self.вб["sender_tags"]:
            with self.subTest(epoch=в["epoch"]):
                self.assertEqual(
                    sender_tag(self._б(в["pair_key"]), в["epoch"]),
                    self._б(в["tag"]))

    def test_префикс_сборка_и_разбор(self):
        """[sent_at сек][seq][кодек][данные] побайтово + обратно."""
        from envelope import encode_revb_prefix, decode_revb_prefix
        for в in self.вб["prefixes"]:
            with self.subTest(seq=в["seq"]):
                байты = encode_revb_prefix(в["sent_at"], в["seq"],
                                           в["inner_codec"],
                                           self._б(в["data"]))
                self.assertEqual(байты, self._б(в["bytes"]))
                sent_at, seq, кодек, данные = decode_revb_prefix(байты)
                self.assertEqual(
                    (sent_at, seq, кодек, данные),
                    (в["sent_at"], в["seq"], в["inner_codec"],
                     self._б(в["data"])))

    def test_позиция_вектора(self):
        """Кодек 7: побайтово из векторов; разбор возвращает поля."""
        from envelope import encode_position_payload, decode_position_payload
        for в in self.вб["positions"]:
            with self.subTest(lat=в["lat"], lon=в["lon"]):
                байты = encode_position_payload(в["precision"], в["lat"],
                                                в["lon"], в["measured_at"])
                self.assertEqual(байты, self._б(в["bytes"]))
                prec, lat, lon, mat = decode_position_payload(байты)
                self.assertEqual((prec, mat),
                                 (в["precision"], в["measured_at"]))
                # разбор возвращает центр шага сетки §5 — сходимость
                # проверяется ре-кодированием в те же байты
                self.assertEqual(
                    encode_position_payload(prec, lat, lon, mat), байты)

    def test_позиция_потолки(self):
        """П3: у каждого поля потолок — выходы за него падают."""
        from envelope import encode_position_payload, decode_position_payload
        for плохие in [dict(precision=13, lat=0, lon=0, measured_at=0),
                       dict(precision=-1, lat=0, lon=0, measured_at=0),
                       dict(precision=0, lat=90.1, lon=0, measured_at=0),
                       dict(precision=0, lat=0, lon=-180.1, measured_at=0),
                       dict(precision=0, lat=0, lon=0, measured_at=1 << 32)]:
            with self.subTest(**плохие):
                with self.assertRaises(ValueError):
                    encode_position_payload(**плохие)
        for обрезок in [b"", b"\x07", b"\x07\x00" + bytes(9),
                        b"\x06\x00" + bytes(10)]:   # не тот кодек
            with self.subTest(данных=len(обрезок)):
                with self.assertRaises(ValueError):
                    decode_position_payload(обрезок)

    def test_sealed2_паритет(self):
        """Кодек 5: seal2 байт в байт с вектором, open2 возвращает всё."""
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PrivateKey)
        from e2e_seal import seal2, open2
        for в in self.вб["sealed2"]:
            a = X25519PrivateKey.from_private_bytes(self._б(в["a_priv"]))
            b = X25519PrivateKey.from_private_bytes(self._б(в["b_priv"]))
            eph = X25519PrivateKey.from_private_bytes(self._б(в["eph_priv"]))
            wire = seal2(self._б(в["plaintext"]), a,
                         b.public_key().public_bytes_raw(),
                         self._б(в["tag"]), eph_priv=eph)
            self.assertEqual(wire, self._б(в["wire"]), "seal2 разошёлся")
            открыт = open2(self._б(в["wire"]), b,
                           a.public_key().public_bytes_raw())
            self.assertEqual(открыт, self._б(в["plaintext"]))

    def test_sealed2_негативы(self):
        """Домены 3↔5, порча тега, чужой отправитель — обязаны падать."""
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PrivateKey)
        from e2e_seal import open2, open_sealed
        н = self.вб["sealed2_negative"]
        b = X25519PrivateKey.from_private_bytes(self._б(н["b_priv"]))
        a_pub = self._б(н["a_pub"])
        with self.assertRaises(Exception):      # шифртекст кодека 3 как 5
            open2(self._б(н["codec3_wire_open2_must_fail"]), b, a_pub)
        with self.assertRaises(Exception):      # sealed2 как кодек 3
            open_sealed(self._б(н["sealed2_wire_open_v0_must_fail"]), b)
        # Домен НЕ равен байту-роутеру: даже подделав байт кодека,
        # шифртекст чужого домена не открывается — ключи разведены KDF
        # (другая соль, другой состав ikm), падает сам AEAD
        подделка35 = bytearray(self._б(н["codec3_wire_open2_must_fail"]))
        подделка35[0] = 5
        with self.assertRaises(Exception):
            open2(bytes(подделка35), b, a_pub)
        подделка53 = bytearray(self._б(н["sealed2_wire_open_v0_must_fail"]))
        подделка53[0] = 3
        with self.assertRaises(Exception):
            open_sealed(bytes(подделка53), b)
        with self.assertRaises(Exception):      # порча тега (он в ad)
            open2(self._б(н["tag_flipped_wire"]), b, a_pub)
        with self.assertRaises(Exception):      # не тот отправитель
            open2(self._б(self.вб["sealed2"][0]["wire"]), b,
                  self._б(н["wrong_sender_pub"]))


class TestFRAG2(unittest.TestCase):
    """B3: нарезка FRAG2 (бит 5) — по векторам и подписанному шву.

    Гейт: FRAG2 строго при >255 кусков старой нарезки; мелочь ходит
    старым блоком u8 (потолок u8-пути v2 поднят 16 → 255 по
    подписанному тексту шва — «≤255 кусков обязаны ходить старой»).
    """

    @classmethod
    def setUpClass(cls):
        путь = (pathlib.Path(__file__).resolve().parent.parent
                / "tests" / "sealed_revb_vectors.json")
        cls.вб = json.loads(путь.read_text(encoding="utf-8"))

    def test_frag2_вектор_побайтово(self):
        """Нарезка совпадает с независимым генератором; разбор сходится."""
        from envelope import encode_v2_text_packets, decode_v2_frame
        в = self.вб["frag2"]
        поток = bytes.fromhex(в["stream"])
        кадры = encode_v2_text_packets(в["msg_id"], поток,
                                       max_payload=в["max_payload"])
        self.assertEqual([к.hex() for к in кадры], в["frames"])
        куски = {}
        for к in кадры:
            f = decode_v2_frame(к)
            self.assertIsNone(f.fragment)
            i, total, msg_len = f.frag2
            self.assertEqual((total, msg_len),
                             (в["total"], в["msg_len"]))
            куски[i] = f.stream
        сборка = b"".join(куски[i] for i in range(в["total"]))
        self.assertEqual(сборка, поток)
        self.assertEqual(len(сборка), в["msg_len"])

    def test_гейт_граница(self):
        """255 старых кусков — старый блок; 256 — FRAG2."""
        from envelope import encode_v2_text_packets, decode_v2_frame
        мп = self.вб["frag2_gate_boundary"]["max_payload"]
        край = self.вб["frag2_gate_boundary"]["stream_len_old_path_max"]

        старые = encode_v2_text_packets(1, bytes(край), max_payload=мп)
        self.assertEqual(len(старые), 255)
        f = decode_v2_frame(старые[254])
        self.assertEqual(f.fragment, (254, 255))   # старый u8-блок
        self.assertIsNone(f.frag2)

        новые = encode_v2_text_packets(1, bytes(край + 1), max_payload=мп)
        f2 = decode_v2_frame(новые[0])
        self.assertIsNone(f2.fragment)
        self.assertIsNotNone(f2.frag2)             # гейт перешагнул

    def test_разбор_потолки(self):
        """Валидации приёмника: взаимоисключение битов, гейт, потолки."""
        from envelope import decode_v2_frame
        якорь = bytes.fromhex("2320341201002c0134080000abcd")
        f = decode_v2_frame(якорь)                 # ручной якорь из спеки
        self.assertEqual(f.frag2, (1, 300, 2100))
        self.assertEqual(f.stream, b"\xAB\xCD")

        def подмена(и, б):
            к = bytearray(якорь); к[и] = б; return bytes(к)

        for плохой in [
            подмена(1, 0x21),        # бит 0 вместе с битом 5
            подмена(1, 0x60),        # бит 6 — по-прежнему ноль
            подмена(7, 0x00),        # total 44 ≤ 255 — обязана старая
            якорь[:6],               # блок обрезан
        ]:
            with self.assertRaises(ValueError):
                decode_v2_frame(плохой)
        # msg_len выше потолка 16 МиБ
        к = bytearray(якорь); к[8:12] = (16777217).to_bytes(4, "little")
        with self.assertRaises(ValueError):
            decode_v2_frame(bytes(к))


if __name__ == "__main__":
    unittest.main()
