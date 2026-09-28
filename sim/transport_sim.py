# -*- coding: utf-8 -*-
"""
transport_sim.py — симулятор LoRa-канала для проекта R+M.

Настоящее радио теряет пакеты, задерживает их, доставляет в другом
порядке и иногда дублирует (в меш-сети один пакет может прийти двумя
путями). Пока железо не приехало, все эти «беды» изображает этот файл —
на нём можно отлаживать фрагментацию, сборку и подтверждения.

Настраивается:
  * loss       — вероятность потери пакета (0.0 … 1.0);
  * duplicate  — вероятность дубликата (пакет приходит дважды);
  * reorder    — вероятность, что пакет «застрянет» и придёт позже
                 отправленных после него (перестановка порядка);
  * delay_min/delay_max — случайная задержка доставки, в секундах;
  * max_payload — лимит полезной нагрузки (200 байт, как у LoRa-пакета
                  Meshtastic); пакет больше лимита в эфир не уходит.

Время здесь виртуальное: канал двигает свои часы сам, ничего не «спит».
Поэтому симуляция мгновенная и полностью воспроизводимая: один и тот же
seed всегда даёт одну и ту же последовательность событий.

Запуск демонстрации:  python3 sim/transport_sim.py
"""

import heapq
import random

# Лимит полезной нагрузки одного LoRa-пакета (байт). Точное значение
# уточним на живом железе (§9 спеки), пока считаем 200.
MAX_PAYLOAD = 200


class LoRaChannel:
    """Односторонний канал «отправитель -> получатель» со всеми бедами радио."""

    def __init__(self, loss=0.0, duplicate=0.0, reorder=0.0,
                 delay_min=0.1, delay_max=1.0, max_payload=MAX_PAYLOAD,
                 seed=None):
        for name, p in (("loss", loss), ("duplicate", duplicate), ("reorder", reorder)):
            if not 0.0 <= p <= 1.0:
                raise ValueError(f"вероятность «{name}» должна быть от 0.0 до 1.0, а не {p}")
        if delay_min < 0 or delay_max < delay_min:
            raise ValueError("нужно 0 ≤ delay_min ≤ delay_max")

        self.loss = loss
        self.duplicate = duplicate
        self.reorder = reorder
        self.delay_min = delay_min
        self.delay_max = delay_max
        self.max_payload = max_payload

        # Свой генератор случайности с seed — чтобы прогон повторялся
        self._rng = random.Random(seed)

        self.now = 0.0        # виртуальные часы канала, секунды
        self._seq = 0         # сквозной номер (чтобы сортировка была устойчивой)
        self._in_flight = []  # куча (время прибытия, номер, пакет)

        # Счётчики для отчёта
        self.stats = {
            "sent": 0,        # попыток отправки
            "delivered": 0,   # доставлено получателю (включая дубликаты)
            "lost": 0,        # потеряно в эфире
            "duplicated": 0,  # создано дубликатов
            "oversize": 0,    # отброшено: больше лимита размера
        }

    # -- отправка ----------------------------------------------------------

    def send(self, packet):
        """Отправляет пакет в канал.

        Возвращает True, если пакет ушёл в эфир, и False, если он больше
        лимита полезной нагрузки (такой пакет радио просто не примет —
        резать на фрагменты должен отправитель заранее).
        """
        self.stats["sent"] += 1
        if len(packet) > self.max_payload:
            self.stats["oversize"] += 1
            return False

        self._launch(packet)

        # Дубликат: в меш-сети пакет может дойти двумя путями.
        # Копия летит независимо — со своей задержкой и своим риском потери.
        if self._rng.random() < self.duplicate:
            self.stats["duplicated"] += 1
            self._launch(packet)
        return True

    def _launch(self, packet):
        """Запускает одну копию пакета: может потеряться или задержаться."""
        if self._rng.random() < self.loss:
            self.stats["lost"] += 1
            return

        delay = self._rng.uniform(self.delay_min, self.delay_max)
        # «Застрявший» пакет: добавляем большую задержку, чтобы он
        # гарантированно пришёл позже отправленных после него
        if self._rng.random() < self.reorder:
            delay += self.delay_max * 2

        self._seq += 1
        heapq.heappush(self._in_flight, (self.now + delay, self._seq, packet))

    # -- получение ---------------------------------------------------------

    def deliver_all(self):
        """Прокручивает время вперёд и отдаёт всё, что долетело.

        Пакеты возвращаются в порядке ПРИБЫТИЯ — из-за случайных задержек
        он может отличаться от порядка отправки.
        """
        out = []
        while self._in_flight:
            arrive_at, _, packet = heapq.heappop(self._in_flight)
            self.now = max(self.now, arrive_at)
            self.stats["delivered"] += 1
            out.append(packet)
        return out

    def in_flight_count(self):
        """Сколько пакетов сейчас «в воздухе»."""
        return len(self._in_flight)

    # -- отчёт -------------------------------------------------------------

    def report(self):
        """Отчёт о работе канала, по-русски."""
        s = self.stats
        return (f"отправлено: {s['sent']}, доставлено: {s['delivered']}, "
                f"потеряно: {s['lost']}, дубликатов: {s['duplicated']}, "
                f"отброшено по размеру: {s['oversize']}")


# ---------------------------------------------------------------------------
# Демонстрация: SOS и длинный текст через плохой канал
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    from envelope import (SOS, Reassembler, TextFragment, decode_packet,
                          encode_text, INJURY_NAMES, NEED_NAMES, SEVERITY_NAMES)

    print("=== Демонстрация симулятора LoRa-канала ===\n")

    # Канал с плохими условиями: 30% потерь, 10% дубликатов,
    # 20% пакетов приходят с опозданием (перестановка порядка)
    channel = LoRaChannel(loss=0.30, duplicate=0.10, reorder=0.20, seed=2026)
    print("Канал: потери 30%, дубликаты 10%, перестановка 20%\n")

    # --- 1. SOS: один пакет, шлём несколько раз для надёжности ---
    sos = SOS(msg_id=0x3BA7, severity=3, people_count=3, injury=1,
              needs={0, 3}, lat=8.71, lon=115.17)
    packet = sos.encode()
    print(f"SOS занимает {len(packet)} байт: {packet.hex(' ')}")

    for _ in range(3):          # SOS повторяют — это дёшево, пакет крошечный
        channel.send(packet)
    arrived = channel.deliver_all()
    print(f"Отправлено 3 копии SOS, дошло: {len(arrived)}")

    if arrived:
        got = decode_packet(arrived[0])
        needs = ", ".join(NEED_NAMES[n] for n in sorted(got.needs))
        print(f"Получен SOS: серьёзность «{SEVERITY_NAMES[got.severity]}», "
              f"людей: {got.people_count}, травма: «{INJURY_NAMES[got.injury]}»,")
        print(f"  нужно: {needs}; координаты ~({got.lat:.4f}, {got.lon:.4f})\n")

    # --- 2. Длинный текст: фрагментация + повторная отправка потерянного ---
    text = ("Тропа к водопаду размыта после ливня, переходить реку вброд "
            "опасно. Идём в обход через восточный хребет, к лагерю выйдем "
            "к закату. Продуктов и воды хватает, рация работает. ") * 4

    packets = encode_text(0x77A1, text)
    print(f"Текст {len(text.encode('utf-8'))} байт разрезан на {len(packets)} фрагментов")

    reassembler = Reassembler()
    result = None
    attempt = 0
    while result is None and attempt < 20:
        attempt += 1
        for p in packets:       # наивная стратегия: слать все фрагменты заново
            channel.send(p)
        for raw in channel.deliver_all():
            item = decode_packet(raw)
            if isinstance(item, TextFragment):
                result = reassembler.add(item, now=channel.now)
                if result is not None:
                    break

    if result == text:
        print(f"Сообщение собрано целиком за {attempt} попыток(и), байт в байт.\n")
    else:
        print("Сообщение собрать не удалось (не повезло с потерями).\n")

    # --- 3. Пакет больше лимита ---
    channel.send(b"\x00" * 250)
    print("Пакет в 250 байт радио не приняло (лимит 200) — это забота кодера.\n")

    print("Итог канала:", channel.report())
