# -*- coding: utf-8 -*-
"""WP5 (автономная сессия 02.08): замер словарного кодека на корпусах.

Метрики: средний размер провода, число пакетов, доля fallback (TEXT),
распределение по длине, airtime по ToA LoRa SF7/BW125/CR4/5 отдельной
колонкой (для интернет-транспорта не применим).

Базовой линии codec_v2_baseline.md не существовало (подготовка к смене
кодека была отменена) — этот замер и ЕСТЬ база текущего кодека.

Плюс контрольное сообщение про отель из брифа.
Запуск: python3 tools/dictation_farm/codec_measure.py (нужен llama:8080)
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "semdict"))

import run_farm as F                                    # noqa: E402
import farm_text as FT                                  # noqa: E402

HOTEL = ("поедем завтра в отель на берегу реки, если погода хорошая — "
         "выдвинемся в 6 утра, если нет — наверно чуть попозже")

MAX_PAYLOAD = 200          # Envelope.maxPayload
HEADER = 4                 # заголовок конверта
TS = 4                     # sentAtMinutes — ОДИН раз в потоке (TEXT v1)
FRAG = 2                   # [номер][всего] в каждом фрагменте
SEAL = 61                  # [0x03][eph 32][nonce 12][tag 16]


def toa_sf7(bytes_total):
    """Time-on-Air, SF7/BW125/CR4/5, преамбула 8, explicit header, CRC.
    Формула Semtech AN1200.13."""
    sf, bw, cr = 7, 125_000.0, 1
    t_sym = (2 ** sf) / bw
    n_pre = 8 + 4.25
    payload_symb = 8 + max(
        math.ceil((8 * bytes_total - 4 * sf + 28 + 16) / (4 * sf))
        * (cr + 4), 0)
    return (n_pre + payload_symb) * t_sym


def wire_cost(blob_len):
    """Полный провод одного сообщения: seal + конверт, с фрагментацией.

    Точно по TextEncoder.encodePackets: метка времени идёт один раз
    префиксом потока, фрагмент несёт 6 Б рамки (заголовок + [i][n]).
    Починено 02.08: прежняя формула клала 8 Б конверта в каждый пакет
    и завышала мультипакетные размеры на 4 Б/пакет со второго.
    """
    sealed = blob_len + 33 + SEAL   # [мой pubkey 32][кодек 1] внутри ct
    stream = TS + sealed
    if HEADER + stream <= MAX_PAYLOAD:
        return HEADER + stream, 1
    chunk = MAX_PAYLOAD - HEADER - FRAG
    packets = math.ceil(stream / chunk)
    return packets * (HEADER + FRAG) + stream, packets


V2_SESSION = 1 + 4 + 2 + 16 + 4 + 1   # кодек+тег+счётчик+AEAD+метка+внутр.кодек
DST = 8                               # адресный блок релея (по радио 0)


def wire_cost_v2(blob_len, relay=False):
    """Провод Envelope v2, кодек 4 (session) — по EnvelopeV2.encodePackets.

    Метка времени внутри шифртекста (№5), отправителя на проводе нет,
    dst 8 Б только для релея.
    """
    stream = V2_SESSION + blob_len
    frame = HEADER + (DST if relay else 0)
    if frame + stream <= MAX_PAYLOAD:
        return frame + stream, 1
    chunk = MAX_PAYLOAD - frame - FRAG
    packets = math.ceil(stream / chunk)
    return packets * (frame + FRAG) + stream, packets


def measure(texts, tag, wire=None):
    wire = wire or wire_cost
    sizes, packets_all, toa_all = [], [], []
    fallback = 0
    n = 0
    for text in texts:
        n += 1
        reason = FT.pre_detect(text)
        r = None
        if reason is None:
            r = FT.encode_with_reason(F, text)
        if not isinstance(r, dict) or r.get("outcome") != "semantic":
            fallback += 1
            payload = len(F.P.zlib_bytes(text)) if hasattr(F.P, "zlib_bytes") \
                else len(__import__("zlib").compress(text.encode(), 9))
        else:
            payload = len(r["blob"]) + 1      # + байт хеша таблицы
        total, pk = wire(payload)
        sizes.append(total)
        packets_all.append(pk)
        toa_all.append(toa_sf7(total))
    sizes.sort()
    dist = {
        "p50": sizes[len(sizes) // 2],
        "p90": sizes[int(len(sizes) * 0.9)],
        "max": sizes[-1],
    }
    print(f"{tag}: n={n}, средний размер {sum(sizes)/n:.0f} Б, "
          f"пакетов в среднем {sum(packets_all)/n:.2f}, "
          f"fallback {fallback}/{n} ({fallback/n*100:.0f}%), "
          f"распределение p50/p90/max = {dist['p50']}/{dist['p90']}/{dist['max']} Б, "
          f"ToA SF7 сред. {sum(toa_all)/n*1000:.0f} мс")
    return dict(n=n, avg=sum(sizes)/n, pk=sum(packets_all)/n,
                fb=fallback, dist=dist, toa=sum(toa_all)/n)


def hotel():
    print("\n— контрольное сообщение про отель —")
    print("вход:", HOTEL, f"({len(HOTEL.encode())} Б utf-8)")
    r = FT.encode_with_reason(F, HOTEL)
    if not isinstance(r, dict) or r.get("outcome") != "semantic":
        print("итог: TEXT-фоллбэк, причина:",
              r.get("reason") if isinstance(r, dict) else r)
        import zlib
        payload = len(zlib.compress(HOTEL.encode(), 9))
    else:
        payload = len(r["blob"]) + 1
        print("пивот:", r["pivot"])
        print("рендер:", r["rendered"])
        print("юниты:", len(r["units"]), "| блоб:", len(r["blob"]), "Б")
    total, pk = wire_cost(payload)
    frame = HEADER + (FRAG if pk > 1 else 0)
    print(f"полный провод: {total} Б / {pk} пакет(а) "
          f"(payload {payload} + seal {SEAL} + pubkey+кодек 33 + "
          f"метка {TS} + рамка {frame}×{pk})")
    print(f"ToA SF7/BW125/CR4/5: {toa_sf7(total)*1000:.0f} мс")


def main():
    # tatoeba-файл жил в скретч-каталоге завершившейся сессии фермы и
    # утрачен вместе с ним — замер по tatoeba невозможен (в отчёт).
    manifest = [m["text"] for m in
                json.load(open(os.path.join(HERE, "out/manifest.json")))]
    # уникальные карточки корпуса (12 карточек × условия — берём тексты)
    uniq = sorted(set(manifest))
    measure(uniq, f"v1 · полевой корпус ({len(uniq)} уник.)")
    measure(uniq, f"v2 радио · полевой корпус ({len(uniq)} уник.)",
            wire=lambda b: wire_cost_v2(b, relay=False))
    measure(uniq, f"v2 релей · полевой корпус ({len(uniq)} уник.)",
            wire=lambda b: wire_cost_v2(b, relay=True))
    hotel()
    print("\n— эталоны v2 (смысловые байты → провод) —")
    for name, payload in [("«ок» (store, 4 Б)", 4),
                          ("отель (semantic, 35 Б)", 35),
                          ("длинное fallback (zlib, 253 Б)", 253)]:
        v1 = wire_cost(payload)
        radio = wire_cost_v2(payload, relay=False)
        relay = wire_cost_v2(payload, relay=True)
        print(f"{name}: v1 {v1[0]} Б/{v1[1]} пак. → "
              f"v2 радио {radio[0]} Б/{radio[1]} · "
              f"v2 релей {relay[0]} Б/{relay[1]}")


if __name__ == "__main__":
    main()
