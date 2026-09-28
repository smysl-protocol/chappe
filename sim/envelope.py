# -*- coding: utf-8 -*-
"""
envelope.py — кодер и декодер пакетов R+M Envelope v0.

Реализует формат из docs/RM_Envelope_v0.md:
  * общий заголовок (4 байта): версия, класс, флаги, msg_id;
  * классы сообщений: SOS, BEACON, TEXT, ACK, LOCATION;
  * координаты двух уровней точности — грубые (~300×600 м) и точные (~1-2 м);
  * битовая маска потребностей (needs, 16 позиций);
  * текстовый хвост со сменным кодеком сжатия;
  * фрагментация и сборка длинных TEXT-сообщений.

Только стандартная библиотека Python, никаких внешних зависимостей.

Главный принцип — КАНОНИЧНОСТЬ (принцип П6 спеки): одни и те же данные
всегда превращаются в один и тот же набор байтов. Поэтому порядок полей
жёстко зашит в коде, а все многобайтовые числа записываются от младшего
байта к старшему (little-endian).

Как запустить проверку:  python3 sim/test_envelope.py
"""

import math
import random
import zlib
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# Константы формата (все числа — из спеки)
# ---------------------------------------------------------------------------

VERSION = 1            # v1 (29.07.2026): TEXT несёт метку отправки
MIN_VERSION = 0        # приёмник принимает 0 и 1 (совместимость)

# Классы сообщений (§3)
CLASS_SOS = 0x1        # сигнал бедствия, широковещательный, не шифруется
CLASS_BEACON = 0x2     # маячок статуса после SOS
CLASS_TEXT = 0x3       # личное текстовое сообщение
CLASS_ACK = 0x4        # подтверждение доставки
CLASS_LOCATION = 0x5   # точные координаты в личном чате

# Флаги в байте 1 заголовка (§4). Бит 0 — младший.
FLAG_FRAGMENTED = 1 << 0   # пакет фрагментирован
FLAG_ACK_REQUEST = 1 << 1  # требуется подтверждение доставки
FLAG_HAS_TAIL = 1 << 2     # есть текстовый хвост
FLAG_HAS_COORDS = 1 << 3   # координаты присутствуют
# биты 4-7 зарезервированы и обязаны быть нулями

HEADER_SIZE = 4        # общий заголовок — всегда 4 байта

MAX_PAYLOAD = 200      # лимит полезной нагрузки одного LoRa-пакета (байт)
MAX_FRAGMENTS = 16     # максимум фрагментов на одно сообщение (§7)
REASSEMBLY_TIMEOUT = 600.0  # неполное сообщение хранится 10 минут (секунды)

# «Координат нет»: поля заполняются единицами (§5)
NO_COARSE = 0xFFFF     # для грубых координат (2 байта)
NO_FINE = 0xFFFFFF     # для точных координат (3 байта)

# Специальные значения счётчиков
PEOPLE_MANY = 63       # people_count: «больше 62 / неизвестно»
RESPONDERS_MANY = 63   # BEACON: «много откликнувшихся»

# Кодеки сжатия текста (§6)
CODEC_STORE = 0        # без сжатия, UTF-8 как есть
CODEC_ZLIB = 1         # zlib / deflate из стандартной библиотеки

# ---------------------------------------------------------------------------
# Справочники «код -> человеческое название» (для интерфейса и демо)
# ---------------------------------------------------------------------------

SEVERITY_NAMES = {0: "низкая", 1: "средняя", 2: "высокая", 3: "критическая"}

INJURY_NAMES = {
    0: "нет травмы",
    1: "кровотечение",
    2: "перелом",
    3: "ожог",
    4: "укус животного/змеи",
    5: "травма головы",
    6: "без сознания",
    7: "утопление",
    8: "отравление",
    15: "другое",
}

NEED_NAMES = {
    0: "бинты / перевязка",
    1: "вода",
    2: "еда",
    3: "лодка",
    4: "транспорт (наземный)",
    5: "врач / медик",
    6: "лекарства",
    7: "эвакуация",
    8: "связь",
    9: "тепло / одежда",
    10: "инструмент",
    11: "помощь в переноске",
    12: "топливо",           # добавлено 25.07.2026 (было резервом)
    13: "укрытие",           # добавлено 25.07.2026 (было резервом)
    15: "другое (см. хвост)",
}

# Соответствие enum-строк модели (схема SOS-извлечения) битам маски.
# Источник истины — tests/needs_mapping.json; тест сверяет этот словарь с ним.
MODEL_NEED_BITS = {
    "bandages": 0,
    "water": 1,
    "food": 2,
    "boat": 3,
    "vehicle": 4,
    "doctor": 5,
    "medicine": 6,
    "evacuation": 7,
    "fuel": 12,
    "shelter": 13,
}

BEACON_STATUS_NAMES = {
    0: "всё ещё нужна помощь",
    1: "помощь идёт",
    2: "ситуация решена",
    3: "резерв",
}

# ---------------------------------------------------------------------------
# Вспомогательные проверки
# ---------------------------------------------------------------------------


def _check_range(name, value, lo, hi):
    """Проверяет, что целое число попадает в допустимый диапазон.

    У каждого поля есть потолок (принцип П3) — выход за него это ошибка
    программиста, о которой надо сказать сразу и по-русски.
    """
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"поле «{name}» должно быть целым числом, а не {value!r}")
    if not lo <= value <= hi:
        raise ValueError(f"поле «{name}» = {value}, а допустимо от {lo} до {hi}")


# ---------------------------------------------------------------------------
# Округление и координаты
# ---------------------------------------------------------------------------


def round_half_up(x):
    """Каноническое округление: floor(x + 0.5), половина всегда вверх.

    Встроенный round() в Python округляет 0.5 «к чётному», в Swift — от нуля.
    Чтобы обе реализации давали одинаковые байты, правило зафиксировано
    в спеке (§5): всегда floor(x + 0.5).
    """
    return math.floor(x + 0.5)


def _check_coords(lat, lon):
    """Проверяет, что широта и долгота в допустимых пределах."""
    if not (-90.0 <= lat <= 90.0):
        raise ValueError(f"широта {lat} вне диапазона -90…90")
    if not (-180.0 <= lon <= 180.0):
        raise ValueError(f"долгота {lon} вне диапазона -180…180")


def encode_coarse_coords(lat, lon):
    """Грубые координаты -> 4 байта (2 широта + 2 долгота, little-endian).

    Точность ~300×600 м — нарочно грубая, для широковещательного SOS.
    """
    _check_coords(lat, lon)
    lat_code = round_half_up((lat + 90.0) / 180.0 * 65535)
    lon_code = round_half_up((lon + 180.0) / 360.0 * 65535)
    return lat_code.to_bytes(2, "little") + lon_code.to_bytes(2, "little")


def decode_coarse_coords(data):
    """4 байта -> (широта, долгота). Обратное преобразование к encode_coarse_coords."""
    lat_code = int.from_bytes(data[0:2], "little")
    lon_code = int.from_bytes(data[2:4], "little")
    lat = lat_code / 65535 * 180.0 - 90.0
    lon = lon_code / 65535 * 360.0 - 180.0
    return lat, lon


def encode_fine_coords(lat, lon):
    """Точные координаты -> 6 байт (3 широта + 3 долгота, little-endian).

    Точность ~1-2 м. Только для класса LOCATION, в личном чате,
    после явного подтверждения пользователем.
    """
    _check_coords(lat, lon)
    lat_code = round_half_up((lat + 90.0) / 180.0 * 16777215)
    lon_code = round_half_up((lon + 180.0) / 360.0 * 16777215)
    return lat_code.to_bytes(3, "little") + lon_code.to_bytes(3, "little")


def decode_fine_coords(data):
    """6 байт -> (широта, долгота). Обратное преобразование к encode_fine_coords."""
    lat_code = int.from_bytes(data[0:3], "little")
    lon_code = int.from_bytes(data[3:6], "little")
    lat = lat_code / 16777215 * 180.0 - 90.0
    lon = lon_code / 16777215 * 360.0 - 180.0
    return lat, lon


# ---------------------------------------------------------------------------
# Битовая маска потребностей (needs, §6)
# ---------------------------------------------------------------------------


def encode_needs(needs):
    """Набор номеров потребностей (0…15) -> 2 байта little-endian.

    Порядок, в котором потребности добавлялись в набор, не влияет на байты —
    маска строится по номерам бит. Это часть каноничности.
    """
    mask = 0
    for bit in needs:
        _check_range("needs (номер бита)", bit, 0, 15)
        mask |= 1 << bit
    return mask.to_bytes(2, "little")


def decode_needs(data):
    """2 байта -> набор номеров потребностей."""
    mask = int.from_bytes(data[0:2], "little")
    return {bit for bit in range(16) if mask & (1 << bit)}


# ---------------------------------------------------------------------------
# Сжатие текста (§6). Кодек сменный, его номер передаётся в пакете.
# ---------------------------------------------------------------------------


def compress_text(text, codec):
    """Текст -> байты по выбранному кодеку."""
    raw = text.encode("utf-8")
    if codec == CODEC_STORE:
        return raw
    if codec == CODEC_ZLIB:
        return zlib.compress(raw, 9)
    raise ValueError(f"неизвестный кодек сжатия: {codec}")


def decompress_text(data, codec):
    """Байты -> текст по выбранному кодеку."""
    if codec == CODEC_STORE:
        return data.decode("utf-8")
    if codec == CODEC_ZLIB:
        return zlib.decompress(data).decode("utf-8")
    raise ValueError(f"неизвестный кодек сжатия: {codec}")


# ---------------------------------------------------------------------------
# Общий заголовок (§4): 4 байта в каждом пакете любого класса
# ---------------------------------------------------------------------------


def _encode_header(msg_class, flags, msg_id):
    """Собирает общий заголовок: [версия|класс] [флаги] [msg_id LE]."""
    _check_range("msg_id", msg_id, 0, 0xFFFF)
    byte0 = (VERSION << 4) | msg_class
    return bytes([byte0, flags]) + msg_id.to_bytes(2, "little")


def _decode_header(packet):
    """Разбирает общий заголовок. Возвращает (класс, флаги, msg_id)."""
    if len(packet) < HEADER_SIZE:
        raise ValueError(f"пакет короче заголовка: {len(packet)} байт, нужно минимум {HEADER_SIZE}")
    version = packet[0] >> 4
    msg_class = packet[0] & 0x0F
    flags = packet[1]
    if not (MIN_VERSION <= version <= VERSION):
        raise ValueError(f"неизвестная версия формата: {version} (поддерживается {VERSION})")
    if flags & 0xF0:
        raise ValueError("зарезервированные флаги (биты 4-7) должны быть нулевыми")
    msg_id = int.from_bytes(packet[2:4], "little")
    return msg_class, flags, msg_id


# ---------------------------------------------------------------------------
# Класс SOS (0x1): широковещательный, не шифруется, не фрагментируется
# ---------------------------------------------------------------------------


@dataclass
class SOS:
    """Сигнал бедствия. Всегда влезает в один пакет (принцип П5).

    Координаты — только грубые (~300×600 м): точные и личность раскрываются
    позже, в личном чате, по явному подтверждению пользователя.
    """
    msg_id: int
    severity: int                    # серьёзность: 0…3 (см. SEVERITY_NAMES)
    people_count: int                # людей: 0…62, 63 = «больше / неизвестно»
    injury: int                      # травма: 0…15 (см. INJURY_NAMES)
    hops_left: int = 3               # сколько раз ещё можно ретранслировать
    lat: Optional[float] = None      # грубая широта (None = нет фикса GPS)
    lon: Optional[float] = None      # грубая долгота
    needs: set = field(default_factory=set)   # номера потребностей 0…15
    text_tail: Optional[str] = None  # необязательное текстовое уточнение
    tail_codec: int = CODEC_STORE    # кодек сжатия хвоста

    def encode(self, max_payload=MAX_PAYLOAD):
        """Собирает SOS в байты. Результат всегда ≤ max_payload."""
        _check_range("severity", self.severity, 0, 3)
        _check_range("people_count", self.people_count, 0, 63)
        _check_range("injury", self.injury, 0, 15)
        _check_range("hops_left", self.hops_left, 0, 15)
        if (self.lat is None) != (self.lon is None):
            raise ValueError("широта и долгота задаются только вместе")

        flags = 0

        # байт 4: severity в старших 2 битах, people_count в младших 6
        # байт 5: injury в старших 4 битах, hops_left в младших 4
        body = bytes([
            (self.severity << 6) | self.people_count,
            (self.injury << 4) | self.hops_left,
        ])

        # байты 6-9: грубые координаты; если фикса нет — единицы (0xFF)
        if self.lat is not None:
            body += encode_coarse_coords(self.lat, self.lon)
            flags |= FLAG_HAS_COORDS
        else:
            body += NO_COARSE.to_bytes(2, "little") * 2

        # байты 10-11: маска потребностей
        body += encode_needs(self.needs)

        # Текстовый хвост — только если ВЕСЬ пакет влезает в один
        # LoRa-пакет. Иначе хвост отбрасывается целиком (принцип П5):
        # у SOS режется хвост, но сам сигнал не фрагментируется никогда.
        tail = b""
        if self.text_tail:
            data = compress_text(self.text_tail, self.tail_codec)
            fits = HEADER_SIZE + len(body) + 2 + len(data) <= max_payload
            if fits and len(data) <= 255:
                tail = bytes([self.tail_codec, len(data)]) + data
                flags |= FLAG_HAS_TAIL

        return _encode_header(CLASS_SOS, flags, self.msg_id) + body + tail

    @classmethod
    def _decode_body(cls, flags, msg_id, packet):
        """Разбирает тело SOS (байты после заголовка)."""
        if len(packet) < 12:
            raise ValueError(f"SOS-пакет слишком короткий: {len(packet)} байт, нужно минимум 12")

        severity = packet[4] >> 6
        people_count = packet[4] & 0x3F
        injury = packet[5] >> 4
        hops_left = packet[5] & 0x0F

        # Присутствие координат определяет флаг 3, а не содержимое байтов
        lat = lon = None
        if flags & FLAG_HAS_COORDS:
            lat, lon = decode_coarse_coords(packet[6:10])

        needs = decode_needs(packet[10:12])

        text_tail = None
        tail_codec = CODEC_STORE
        if flags & FLAG_HAS_TAIL:
            if len(packet) < 14:
                raise ValueError("флаг хвоста установлен, а хвоста нет")
            tail_codec = packet[12]
            length = packet[13]
            data = packet[14:14 + length]
            if len(data) != length:
                raise ValueError(f"хвост оборван: заявлено {length} байт, есть {len(data)}")
            text_tail = decompress_text(data, tail_codec)

        return cls(msg_id=msg_id, severity=severity, people_count=people_count,
                   injury=injury, hops_left=hops_left, lat=lat, lon=lon,
                   needs=needs, text_tail=text_tail, tail_codec=tail_codec)


# ---------------------------------------------------------------------------
# Класс BEACON (0x2): маячок статуса после SOS (§5б)
# ---------------------------------------------------------------------------


@dataclass
class Beacon:
    """Маячок статуса. Шлёт его сам пострадавший — чтобы у спасателей
    на карте была свежая картина.

    Важное правило спеки: статус выставляет только сам пострадавший.
    Число откликнувшихся — это не статус: пока человек сам не переключил
    на «помощь идёт», статус остаётся «нужна помощь».
    """
    msg_id: int
    sos_msg_id: int                  # msg_id исходного SOS
    status: int                      # 0…3 (см. BEACON_STATUS_NAMES)
    responders: int                  # откликнувшихся: 0…62, 63 = «много»
    lat: Optional[float] = None      # грубые координаты, если переместился
    lon: Optional[float] = None

    def encode(self):
        """Собирает BEACON в байты."""
        _check_range("sos_msg_id", self.sos_msg_id, 0, 0xFFFF)
        _check_range("status", self.status, 0, 3)
        _check_range("responders", self.responders, 0, 63)
        if (self.lat is None) != (self.lon is None):
            raise ValueError("широта и долгота задаются только вместе")

        flags = 0
        # байты 4-5: msg_id исходного SOS
        # байт 6: статус в старших 2 битах, откликнувшиеся в младших 6
        body = self.sos_msg_id.to_bytes(2, "little")
        body += bytes([(self.status << 6) | self.responders])

        # байты 7-10: грубые координаты — только если человек переместился
        if self.lat is not None:
            body += encode_coarse_coords(self.lat, self.lon)
            flags |= FLAG_HAS_COORDS

        return _encode_header(CLASS_BEACON, flags, self.msg_id) + body

    @classmethod
    def _decode_body(cls, flags, msg_id, packet):
        """Разбирает тело BEACON."""
        if len(packet) < 7:
            raise ValueError(f"BEACON-пакет слишком короткий: {len(packet)} байт, нужно минимум 7")
        sos_msg_id = int.from_bytes(packet[4:6], "little")
        status = packet[6] >> 6
        responders = packet[6] & 0x3F
        lat = lon = None
        if flags & FLAG_HAS_COORDS:
            if len(packet) < 11:
                raise ValueError("флаг координат установлен, а координат нет")
            lat, lon = decode_coarse_coords(packet[7:11])
        return cls(msg_id=msg_id, sos_msg_id=sos_msg_id, status=status,
                   responders=responders, lat=lat, lon=lon)


# ---------------------------------------------------------------------------
# Класс ACK (0x4): подтверждение доставки (§5а)
# ---------------------------------------------------------------------------


@dataclass
class Ack:
    """Подтверждение доставки. Отвечает на пакет с флагом 1."""
    msg_id: int       # свой, новый msg_id этого ACK
    ack_msg_id: int   # msg_id сообщения, которое подтверждаем

    def encode(self):
        """Собирает ACK в байты: заголовок + 2 байта подтверждаемого msg_id."""
        _check_range("ack_msg_id", self.ack_msg_id, 0, 0xFFFF)
        return _encode_header(CLASS_ACK, 0, self.msg_id) + self.ack_msg_id.to_bytes(2, "little")

    @classmethod
    def _decode_body(cls, flags, msg_id, packet):
        """Разбирает тело ACK."""
        if len(packet) < 6:
            raise ValueError(f"ACK-пакет слишком короткий: {len(packet)} байт, нужно минимум 6")
        return cls(msg_id=msg_id, ack_msg_id=int.from_bytes(packet[4:6], "little"))


# ---------------------------------------------------------------------------
# Класс LOCATION (0x5): точные координаты в личном чате
# ---------------------------------------------------------------------------


@dataclass
class Location:
    """Точные координаты (~1-2 м). Только личный чат, только после
    явного подтверждения пользователем в интерфейсе.
    """
    msg_id: int
    lat: Optional[float] = None   # None = нет фикса GPS
    lon: Optional[float] = None
    want_ack: bool = False        # просить подтверждение доставки

    def encode(self):
        """Собирает LOCATION в байты: заголовок + 6 байт точных координат."""
        if (self.lat is None) != (self.lon is None):
            raise ValueError("широта и долгота задаются только вместе")
        flags = FLAG_ACK_REQUEST if self.want_ack else 0
        if self.lat is not None:
            body = encode_fine_coords(self.lat, self.lon)
            flags |= FLAG_HAS_COORDS
        else:
            body = NO_FINE.to_bytes(3, "little") * 2
        return _encode_header(CLASS_LOCATION, flags, self.msg_id) + body

    @classmethod
    def _decode_body(cls, flags, msg_id, packet):
        """Разбирает тело LOCATION."""
        if len(packet) < 10:
            raise ValueError(f"LOCATION-пакет слишком короткий: {len(packet)} байт, нужно минимум 10")
        lat = lon = None
        if flags & FLAG_HAS_COORDS:
            lat, lon = decode_fine_coords(packet[4:10])
        return cls(msg_id=msg_id, lat=lat, lon=lon,
                   want_ack=bool(flags & FLAG_ACK_REQUEST))


# ---------------------------------------------------------------------------
# Класс TEXT (0x3): личное сообщение, единственный фрагментируемый класс
# ---------------------------------------------------------------------------


@dataclass
class TextMessage:
    """Текстовое сообщение, целиком уместившееся в один пакет."""
    msg_id: int
    text: str
    codec: int = CODEC_STORE
    want_ack: bool = False
    sent_at_minutes: int = 0     # unix-минуты отправки (v1; 0 = нет)


@dataclass
class TextFragment:
    """Один фрагмент длинного текстового сообщения.

    Сборка целого сообщения из фрагментов — задача класса Reassembler.
    """
    msg_id: int
    index: int      # номер фрагмента, от 0
    total: int      # всего фрагментов
    chunk: bytes    # кусок полезной нагрузки
    want_ack: bool = False


def encode_text(msg_id, text, codec=CODEC_STORE, want_ack=False, max_payload=MAX_PAYLOAD, sent_at_minutes=0):
    """Собирает текстовое сообщение в один или несколько пакетов.

    Возвращает список байтовых пакетов. Если текст влезает в один пакет —
    в списке один элемент без фрагментации. Если нет — текст режется на
    фрагменты (не больше 16, §7). Длину считает код, не модель (принцип П4).

    Полезная нагрузка: [кодек: 1 байт][сжатые байты текста].
    """
    # v1: 4 байта unix-минут отправки — ПРЕФИКС потока нагрузки
    # (0 = неизвестно); фрагментация режет поток как раньше (Ф5)
    payload = (sent_at_minutes.to_bytes(4, "little")
               + bytes([codec]) + compress_text(text, codec))
    base_flags = FLAG_ACK_REQUEST if want_ack else 0

    # Помещается целиком — один пакет, без блока фрагментации
    if HEADER_SIZE + len(payload) <= max_payload:
        return [_encode_header(CLASS_TEXT, base_flags, msg_id) + payload]

    # Не помещается — режем. В каждом фрагменте после заголовка идут
    # 2 байта: [номер фрагмента][всего фрагментов] (§7)
    chunk_size = max_payload - HEADER_SIZE - 2
    chunks = [payload[i:i + chunk_size] for i in range(0, len(payload), chunk_size)]
    if len(chunks) > MAX_FRAGMENTS:
        raise ValueError(
            f"сообщение требует {len(chunks)} фрагментов, а максимум {MAX_FRAGMENTS}; "
            f"текст надо сократить (это делает код приложения, не модель)")

    flags = base_flags | FLAG_FRAGMENTED
    packets = []
    for index, chunk in enumerate(chunks):
        header = _encode_header(CLASS_TEXT, flags, msg_id)
        packets.append(header + bytes([index, len(chunks)]) + chunk)
    return packets


def decode_text_payload(payload):
    """Разбирает собранную полезную нагрузку TEXT: [кодек][сжатые байты].

    Возвращает (кодек, текст).
    """
    if len(payload) < 1:
        raise ValueError("пустая полезная нагрузка TEXT")
    codec = payload[0]
    return codec, decompress_text(payload[1:], codec)


# ---------------------------------------------------------------------------
# Общий вход: разобрать любой пакет
# ---------------------------------------------------------------------------


def decode_packet(packet):
    """Разбирает пакет любого класса.

    Возвращает объект SOS, Beacon, TextMessage, TextFragment, Ack
    или Location — в зависимости от класса в заголовке.
    """
    msg_class, flags, msg_id = _decode_header(packet)

    if msg_class == CLASS_SOS:
        return SOS._decode_body(flags, msg_id, packet)
    if msg_class == CLASS_BEACON:
        return Beacon._decode_body(flags, msg_id, packet)
    if msg_class == CLASS_ACK:
        return Ack._decode_body(flags, msg_id, packet)
    if msg_class == CLASS_LOCATION:
        return Location._decode_body(flags, msg_id, packet)

    if msg_class == CLASS_TEXT:
        want_ack = bool(flags & FLAG_ACK_REQUEST)
        if flags & FLAG_FRAGMENTED:
            # Фрагмент: 2 байта блока фрагментации, затем кусок нагрузки
            if len(packet) < HEADER_SIZE + 2:
                raise ValueError("фрагмент без блока фрагментации")
            index, total = packet[4], packet[5]
            if total < 1 or total > MAX_FRAGMENTS:
                raise ValueError(f"недопустимое число фрагментов: {total}")
            if index >= total:
                raise ValueError(f"номер фрагмента {index} ≥ общего числа {total}")
            return TextFragment(msg_id=msg_id, index=index, total=total,
                                chunk=packet[6:], want_ack=want_ack)
        stream = packet[4:]
        sent_at = 0
        if (packet[0] >> 4) >= 1:            # v1: 4 байта метки в потоке
            if len(stream) < 4:
                raise ValueError("v1 TEXT без метки времени")
            sent_at = int.from_bytes(stream[:4], "little")
            stream = stream[4:]
        codec, text = decode_text_payload(stream)
        return TextMessage(msg_id=msg_id, text=text, codec=codec,
                           want_ack=want_ack, sent_at_minutes=sent_at)

    raise ValueError(f"неизвестный класс сообщения: {msg_class}")


# ---------------------------------------------------------------------------
# Сборка фрагментов (§7)
# ---------------------------------------------------------------------------


class Reassembler:
    """Собирает длинные TEXT-сообщения из фрагментов.

    Правила из §7 спеки:
      * сборка по msg_id;
      * фрагменты могут прийти в любом порядке;
      * дубликаты отбрасываются;
      * неполное сообщение хранится 10 минут, потом отбрасывается.

    Время передаётся снаружи (параметр now в секундах) — так поведение
    полностью воспроизводимо в тестах, без обращения к настоящим часам.
    """

    def __init__(self, timeout=REASSEMBLY_TIMEOUT):
        self._timeout = timeout
        # msg_id -> {"total": ..., "parts": {номер: байты}, "born": время}
        self._pending = {}

    def _purge(self, now):
        """Выбрасывает недособранные сообщения, которые ждут дольше лимита."""
        expired = [mid for mid, rec in self._pending.items()
                   if now - rec["born"] > self._timeout]
        for mid in expired:
            del self._pending[mid]

    def add(self, fragment, now=0.0):
        """Принимает один фрагмент.

        Возвращает собранный текст, если этот фрагмент был последним
        недостающим, иначе None.
        """
        self._purge(now)

        rec = self._pending.get(fragment.msg_id)
        if rec is None:
            rec = {"total": fragment.total, "parts": {}, "born": now}
            self._pending[fragment.msg_id] = rec
        elif fragment.total != rec["total"]:
            raise ValueError(
                f"фрагменты msg_id={fragment.msg_id:#06x} сообщают разное "
                f"общее число частей: {rec['total']} и {fragment.total}")

        # Дубликат (фрагмент с уже известным номером) просто игнорируется
        rec["parts"].setdefault(fragment.index, fragment.chunk)

        if len(rec["parts"]) < rec["total"]:
            return None  # ещё не всё пришло

        # Все фрагменты на месте: склеиваем по номерам и разбираем
        payload = b"".join(rec["parts"][i] for i in range(rec["total"]))
        # v1: собранный поток начинается с 4 байт метки отправки
        if payload[:1] and rec.get("version", 1) >= 1 and len(payload) >= 4:
            payload = payload[4:]
        del self._pending[fragment.msg_id]
        _codec, text = decode_text_payload(payload)
        return text

    def pending_count(self):
        """Сколько сообщений сейчас ждут недостающих фрагментов."""
        return len(self._pending)


# ---------------------------------------------------------------------------
# Мелкая утилита
# ---------------------------------------------------------------------------


def new_msg_id(rng=None):
    """Случайный 16-битный идентификатор сообщения (§4)."""
    return (rng or random).randrange(0, 0x10000)


# ---------------------------------------------------------------------------
# Ревизия B (шов docs/reports/wire_revision_b_location_seam.md, 11.08.2026):
# общий префикс плейнтекста кодеков 5/6 и внутренний кодек 7 «позиция».
# Крипточасть sealed2 — в e2e_seal.py; здесь только байтовые раскладки.
# ---------------------------------------------------------------------------

CODEC_SEALED2 = 5      # запечатанный кадр известной паре (провод в e2e_seal)
CODEC_SESSION2 = 6     # кадр эпохи рэтчета с префиксом рев B (Swift)
CODEC_POSITION = 7     # ВНУТРЕННИЙ кодек: полезная нагрузка — позиция

_POSITION_SIZE = 12    # [7][precision][lat 3][lon 3][measured_at 4]


def encode_revb_prefix(sent_at, seq, inner_codec, data):
    """[sent_at unix-секунды u32 LE][seq u32 LE][внутренний кодек][данные].

    sent_at — косметика показа; порядок ленты держит seq (монотонный
    счётчик пары, часы отправителя доказанно врут — полевое 10.08).
    """
    _check_range("sent_at", sent_at, 0, 0xFFFFFFFF)
    _check_range("seq", seq, 0, 0xFFFFFFFF)
    _check_range("inner_codec", inner_codec, 0, 0xFF)
    return (sent_at.to_bytes(4, "little") + seq.to_bytes(4, "little")
            + bytes([inner_codec]) + bytes(data))


def decode_revb_prefix(stream):
    """Обратное к encode_revb_prefix -> (sent_at, seq, кодек, данные)."""
    if len(stream) < 9:
        raise ValueError(f"префикс рев B: нужно ≥9 байт, получено {len(stream)}")
    return (int.from_bytes(stream[0:4], "little"),
            int.from_bytes(stream[4:8], "little"),
            stream[8], bytes(stream[9:]))


def encode_position_payload(precision, lat, lon, measured_at):
    """Кодек 7: [0x07][precision][lat 3 LE][lon 3 LE][measured_at u32 LE].

    precision: 0 = exact, 1–12 = длина ячейки геохеша загрубления
    (координата обязана быть уже центром ячейки — загрубляет дверь WP4
    ДО конверта). Координаты — канон §5 fine, второго формата нет.
    """
    _check_range("precision", precision, 0, 12)
    _check_range("measured_at", measured_at, 0, 0xFFFFFFFF)
    return (bytes([CODEC_POSITION, precision]) + encode_fine_coords(lat, lon)
            + measured_at.to_bytes(4, "little"))


def decode_position_payload(data):
    """Обратное к encode_position_payload -> (precision, lat, lon, measured_at)."""
    if len(data) != _POSITION_SIZE:
        raise ValueError(
            f"позиция: нужно ровно {_POSITION_SIZE} байт, получено {len(data)}")
    if data[0] != CODEC_POSITION:
        raise ValueError(f"это не позиция: кодек {data[0]}, ожидался {CODEC_POSITION}")
    precision = data[1]
    _check_range("precision", precision, 0, 12)
    lat, lon = decode_fine_coords(data[2:8])
    return precision, lat, lon, int.from_bytes(data[8:12], "little")


# ---------------------------------------------------------------------------
# B3: v2-рамка TEXT с нарезкой FRAG2 (бит 5) — зеркало EnvelopeV2.swift.
# Гейт подписан владельцем 11.08: FRAG2 СТРОГО при >255 кусков старой
# нарезки; ≤255 кусков обязаны ходить старым блоком u8 (потолок u8-пути
# v2 — 255 по тексту шва; v0/v1-путь TEXT остаётся с MAX_FRAGMENTS=16).
# ---------------------------------------------------------------------------

import collections

V2_VERSION = 2
V2_CLASS_TEXT = 0x3
V2_FLAG_FRAGMENTED = 1 << 0
V2_FLAG_ACK = 1 << 1
V2_FLAG_ADDRESS = 1 << 4
V2_FLAG_FRAG2 = 1 << 5
V2_DST_LEN = 8
V2_MAX_FRAGMENTS_U8 = 255       # старый блок [index u8][total u8]
FRAG2_MAX_TOTAL = 0xFFFF
FRAG2_MSG_LEN_CAP = 16777216    # 16 МиБ (П3)
FRAG2_MAX_FRAME = 0xFFFF        # длина u16 в обёртке WirePadding (№7)

V2Frame = collections.namedtuple(
    "V2Frame", "msg_id want_ack dst fragment frag2 stream")


def encode_v2_text_packets(msg_id, stream, dst=b"", want_ack=False,
                           max_payload=MAX_PAYLOAD):
    """Пакует поток в v2-рамку TEXT: целиком, старым блоком u8 или FRAG2."""
    if dst and len(dst) != V2_DST_LEN:
        raise ValueError(f"dst обязан быть {V2_DST_LEN} Б")
    flags = (V2_FLAG_ACK if want_ack else 0) \
        | (V2_FLAG_ADDRESS if dst else 0)
    заголовок = bytes([(V2_VERSION << 4) | V2_CLASS_TEXT])

    def кадр(доп_флаги, тело):
        к = (заголовок + bytes([flags | доп_флаги])
             + msg_id.to_bytes(2, "little") + bytes(dst) + тело)
        if len(к) > FRAG2_MAX_FRAME:
            raise ValueError(
                f"кадр {len(к)} Б выше потолка обёртки №7 ({FRAG2_MAX_FRAME})")
        return к

    per = HEADER_SIZE + len(dst)
    if per + len(stream) <= max_payload:
        return [кадр(0, bytes(stream))]

    # гейт: сначала старая нарезка (блок 2 Б)
    кусок_ст = max_payload - per - 2
    куски = [stream[i:i + кусок_ст] for i in range(0, len(stream), кусок_ст)]
    if len(куски) <= V2_MAX_FRAGMENTS_U8:
        return [кадр(V2_FLAG_FRAGMENTED, bytes([i, len(куски)]) + bytes(к))
                for i, к in enumerate(куски)]

    # FRAG2: >255 кусков — блок [index u16][total u16][msg_len u32]
    кусок2 = max_payload - per - 8
    куски = [stream[i:i + кусок2] for i in range(0, len(stream), кусок2)]
    total, msg_len = len(куски), len(stream)
    if total > FRAG2_MAX_TOTAL:
        raise ValueError(f"FRAG2: {total} кусков выше потолка {FRAG2_MAX_TOTAL}")
    if msg_len > FRAG2_MSG_LEN_CAP:
        raise ValueError(f"FRAG2: {msg_len} Б выше потолка {FRAG2_MSG_LEN_CAP}")
    return [кадр(V2_FLAG_FRAG2,
                 i.to_bytes(2, "little") + total.to_bytes(2, "little")
                 + msg_len.to_bytes(4, "little") + bytes(к))
            for i, к in enumerate(куски)]


def decode_v2_frame(packet):
    """Разбирает v2-кадр TEXT -> V2Frame. Валидации приёмника B3."""
    if len(packet) < HEADER_SIZE:
        raise ValueError("v2: пакет короче заголовка")
    if packet[0] >> 4 != V2_VERSION:
        raise ValueError("это не v2-пакет")
    if packet[0] & 0x0F != V2_CLASS_TEXT:
        raise ValueError(f"v2: неизвестный класс {packet[0] & 0x0F}")
    flags = packet[1]
    if flags & 0b1100_0000:
        raise ValueError("v2: зарезервированные флаги (биты 6-7) не нулевые")
    if flags & V2_FLAG_FRAGMENTED and flags & V2_FLAG_FRAG2:
        raise ValueError("v2: биты 0 и 5 взаимоисключающие")
    msg_id = int.from_bytes(packet[2:4], "little")
    rest = packet[HEADER_SIZE:]

    dst = None
    if flags & V2_FLAG_ADDRESS:
        if len(rest) < V2_DST_LEN:
            raise ValueError("v2: адресный блок обрезан")
        dst, rest = bytes(rest[:V2_DST_LEN]), rest[V2_DST_LEN:]

    fragment = frag2 = None
    if flags & V2_FLAG_FRAGMENTED:
        if len(rest) <= 2:
            raise ValueError("v2: фрагмент без блока фрагментации")
        index, total = rest[0], rest[1]
        if not (1 <= total <= V2_MAX_FRAGMENTS_U8 and index < total):
            raise ValueError("v2: недопустимая фрагментация")
        fragment, rest = (index, total), rest[2:]
    elif flags & V2_FLAG_FRAG2:
        if len(rest) <= 8:
            raise ValueError("FRAG2: блок обрезан")
        index = int.from_bytes(rest[0:2], "little")
        total = int.from_bytes(rest[2:4], "little")
        msg_len = int.from_bytes(rest[4:8], "little")
        if total <= V2_MAX_FRAGMENTS_U8:
            raise ValueError(
                f"FRAG2: total {total} ≤ 255 — обязана старая нарезка (гейт)")
        if index >= total:
            raise ValueError("FRAG2: index ≥ total")
        if msg_len > FRAG2_MSG_LEN_CAP:
            raise ValueError(f"FRAG2: msg_len выше потолка {FRAG2_MSG_LEN_CAP}")
        frag2, rest = (index, total, msg_len), rest[8:]

    return V2Frame(msg_id=msg_id, want_ack=bool(flags & V2_FLAG_ACK),
                   dst=dst, fragment=fragment, frag2=frag2,
                   stream=bytes(rest))
