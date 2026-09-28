# -*- coding: utf-8 -*-
"""Генератор векторов ревизии B (кодеки 5/6/7) — НЕЗАВИСИМАЯ реализация.

Спека: docs/reports/wire_revision_b_location_seam.md (подпись владельца
11.08.2026, тег Т1). Правило 4 CLAUDE.md: вектора считаются из спеки
руками или ДРУГОЙ реализацией, не из вывода проверяемого кода. Этот
скрипт — та самая другая реализация: он собирает байты напрямую из
сырых примитивов cryptography шаг за шагом по тексту шва и НЕ
импортирует ни sim/envelope.py, ни sim/e2e_seal.py. Ручные якоря
(байты, посчитанные на бумаге) зашиты assert-ами: если формула
генератора разойдётся с бумагой — генератор падает, а не пишет вектора.

Запуск (tests/ под замком корпусов, разлочка по постановке владельца):
    RM_CORPUS_UNLOCK=1 python3 sim/sealed_revb_vectors_gen.py
"""
import hashlib
import hmac as hmac_mod
import json
import math
import os

from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey, X25519PublicKey)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

# ---------------------------------------------------------------- примитивы

def hmac256(key, msg):
    return hmac_mod.new(key, msg, hashlib.sha256).digest()


def le16(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF])


def le24(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF])


def le32(v):
    return bytes([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF,
                  (v >> 24) & 0xFF])


# ------------------------------------------------- шов: тег отправителя Т1

def sender_tag(pair_key, epoch):
    """tag = HMAC-SHA256(pairKey, "sender-tag" ‖ epoch u32 LE)[0..2]."""
    return hmac256(pair_key, b"sender-tag" + le32(epoch))[:2]


# ------------------------------------------------- шов: общий префикс рев B

def revb_prefix(sent_at, seq, inner_codec, data):
    """[sent_at unix-секунды u32 LE][seq u32 LE][внутренний кодек][данные]"""
    return le32(sent_at) + le32(seq) + bytes([inner_codec]) + bytes(data)


# ------------------------------------------------- шов: позиция (кодек 7)

def position_payload(precision, lat, lon, measured_at):
    """[0x07][precision][lat 3 LE][lon 3 LE][measured_at u32 LE].

    Координаты — канон Envelope §5 fine: код = floor((x+сдвиг)/охват
    × 16777215 + 0.5), little-endian 3 байта на ось.
    """
    lat_code = math.floor((lat + 90.0) / 180.0 * 16777215 + 0.5)
    lon_code = math.floor((lon + 180.0) / 360.0 * 16777215 + 0.5)
    return (bytes([0x07, precision]) + le24(lat_code) + le24(lon_code)
            + le32(measured_at))


# ------------------------------------------------- шов: sealed2 (кодек 5)

SALT2 = b"RM-Smysl-v1"


def seal2(plaintext, a_priv, b_pub_bytes, eph_priv, tag):
    """[0x05][eph_pub 32][tag 2][ct][aead 16]; nonce из HKDF, не с провода.

    ikm = DH(eph, B) ‖ DH(A, B); HKDF-SHA256(salt="RM-Smysl-v1",
    info = eph_pub ‖ B_pub ‖ A_pub, 44) → key 32 ‖ nonce 12;
    ad = [0x05] ‖ eph_pub ‖ tag.
    """
    eph_pub = eph_priv.public_key().public_bytes_raw()
    a_pub = a_priv.public_key().public_bytes_raw()
    b_pub = X25519PublicKey.from_public_bytes(b_pub_bytes)
    ikm = eph_priv.exchange(b_pub) + a_priv.exchange(b_pub)
    okm = HKDF(algorithm=hashes.SHA256(), length=44, salt=SALT2,
               info=eph_pub + b_pub_bytes + a_pub).derive(ikm)
    key, nonce = okm[:32], okm[32:]
    ad = bytes([0x05]) + eph_pub + tag
    ct = ChaCha20Poly1305(key).encrypt(nonce, bytes(plaintext), ad)
    return bytes([0x05]) + eph_pub + tag + ct


def seal_v0(payload, recipient_pub_bytes, eph_priv, nonce):
    """Замороженный кодек 3 (для негативного вектора 3↔5):
    [3][eph 32][nonce 12 + ct + tag], ключ HKDF salt v0, ikm = один DH."""
    eph_pub = eph_priv.public_key().public_bytes_raw()
    shared = eph_priv.exchange(
        X25519PublicKey.from_public_bytes(recipient_pub_bytes))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=b"RM-Smysl-v0",
               info=eph_pub + recipient_pub_bytes).derive(shared)
    ct = ChaCha20Poly1305(key).encrypt(nonce, bytes(payload), None)
    return bytes([3]) + eph_pub + nonce + ct


# ------------------------------------------------- шов: session2 (кодек 6)

def ratchet_stream(codec, seed, initiator, counter, plaintext):
    """Кадр рэтчета Б: [codec][тег 4][счётчик 2 LE][ct][aead 16].

    tagKey = HMAC(seed,"tag"); ck = HMAC(seed, "init"/"resp"), прокрутка
    ck' = HMAC(ck,[2]) до счётчика; mk = HMAC(ck,[1]), nonce =
    HMAC(ck,[3])[0..12]; тег = HMAC(tagKey,[dir, счётчик LE])[0..4];
    ad = [codec] ‖ тег ‖ счётчик. Кодек 4 и 6 различаются байтом кодека
    в ad (домены) и плейнтекстом (6 — префикс рев B).
    """
    tag_key = hmac256(seed, b"tag")
    ck = hmac256(seed, b"init" if initiator else b"resp")
    for _ in range(counter):
        ck = hmac256(ck, bytes([2]))
    mk = hmac256(ck, bytes([1]))
    nonce = hmac256(ck, bytes([3]))[:12]
    tag = hmac256(tag_key, bytes([1 if initiator else 0]) + le16(counter))[:4]
    ad = bytes([codec]) + tag + le16(counter)
    ct = ChaCha20Poly1305(mk).encrypt(nonce, bytes(plaintext), ad)
    return ad + ct


# ------------------------------------------------- шов B3: FRAG2 (бит 5)

FLAG_ACK = 1 << 1
FLAG_ADDR = 1 << 4
FLAG_FRAG2 = 1 << 5
V2_TEXT_HEADER0 = (2 << 4) | 0x3     # версия 2, класс TEXT


def frag2_packets(msg_id, stream, dst=b"", want_ack=False, max_payload=200):
    """Независимая нарезка FRAG2 по спеке B3 шва.

    Кадр: [23][flags|0x20][msgID LE][dst?][index u16][total u16]
    [msg_len u32][кусок]. Гейт: FRAG2 ТОЛЬКО когда старая нарезка
    (блок 2 Б, u8) требует >255 кусков.
    """
    per = 4 + len(dst)
    chunk_old = max_payload - per - 2
    n_old = -(-len(stream) // chunk_old)          # ceil
    assert n_old > 255, "вектор FRAG2 обязан требовать >255 кусков"
    chunk2 = max_payload - per - 8
    chunks = [stream[i:i + chunk2] for i in range(0, len(stream), chunk2)]
    total, msg_len = len(chunks), len(stream)
    assert 256 <= total <= 0xFFFF and msg_len <= 16777216
    flags = (FLAG_ACK if want_ack else 0) | (FLAG_ADDR if dst else 0) \
        | FLAG_FRAG2
    return [bytes([V2_TEXT_HEADER0, flags]) + le16(msg_id) + dst
            + le16(i) + le16(total) + le32(msg_len) + c
            for i, c in enumerate(chunks)]


# ---------------------------------------------------------------- вектора

def main():
    # -------- ручные якоря (посчитаны на бумаге, спека §5 и шов) --------
    # Позиция (0,0), exact, measured_at 0x01020304:
    # обе оси: (0+90)/180 = 0.5; 0.5×16777215 = 8388607.5; +0.5 → 8388608
    # = 0x800000 → LE «00 00 80». Итого 12 байт:
    assert position_payload(0, 0.0, 0.0, 0x01020304).hex() == \
        "070000008000008004030201", "якорь позиции разошёлся с бумагой"
    # Префикс: sent_at 0x66554433 → LE «33 44 55 66», seq 1 → «01 00 00 00»,
    # кодек 7, данных нет:
    assert revb_prefix(0x66554433, 1, 7, b"").hex() == "3344556601000000" \
        "07", "якорь префикса разошёлся с бумагой"

    # -------- фиксированные ключи векторов --------
    a_priv = X25519PrivateKey.from_private_bytes(bytes([0x11] * 32))  # A
    b_priv = X25519PrivateKey.from_private_bytes(bytes([0x22] * 32))  # B
    eph = X25519PrivateKey.from_private_bytes(bytes([0x33] * 32))
    stranger = X25519PrivateKey.from_private_bytes(bytes([0x44] * 32))
    a_pub = a_priv.public_key().public_bytes_raw()
    b_pub = b_priv.public_key().public_bytes_raw()

    pair_key = bytes([0xA5] * 32)
    seed = bytes(range(32))

    vectors = {
        "title": "Вектора ревизии B: кодеки 5 (sealed2), 6 (session2), "
                 "7 (position), тег Т1, префикс sent_at+seq",
        "spec": "docs/reports/wire_revision_b_location_seam.md",
        "generator": "sim/sealed_revb_vectors_gen.py — сырые примитивы, "
                     "не реализации-участники",
    }

    # -------- тег отправителя Т1 --------
    vectors["sender_tags"] = [
        {"pair_key": pair_key.hex(), "epoch": e,
         "tag": sender_tag(pair_key, e).hex()}
        for e in (0, 20665, 20666)
    ]

    # -------- префикс рев B --------
    vectors["prefixes"] = [
        {"sent_at": 0x66554433, "seq": 1, "inner_codec": 7, "data": "",
         "bytes": revb_prefix(0x66554433, 1, 7, b"").hex()},
        {"sent_at": 1786500000, "seq": 4242, "inner_codec": 0,
         "data": b"ok".hex(),
         "bytes": revb_prefix(1786500000, 4242, 0, b"ok").hex()},
    ]

    # -------- позиция (кодек 7) --------
    vectors["positions"] = [
        {"precision": 0, "lat": 0.0, "lon": 0.0,
         "measured_at": 0x01020304,
         "bytes": position_payload(0, 0.0, 0.0, 0x01020304).hex()},
        # Сайгон, точно; measured_at 11.08.2026 09:00 UTC = 1786525200
        {"precision": 0, "lat": 10.762622, "lon": 106.660172,
         "measured_at": 1786525200,
         "bytes": position_payload(0, 10.762622, 106.660172,
                                   1786525200).hex()},
        # загрубление до ячейки геохеша длины 5 (~4.9 км): в байтах
        # уже центр ячейки — здесь просто фиксируем precision=5
        {"precision": 5, "lat": -8.65, "lon": 115.2166,
         "measured_at": 1786525260,
         "bytes": position_payload(5, -8.65, 115.2166, 1786525260).hex()},
        # края диапазонов
        {"precision": 12, "lat": -90.0, "lon": -180.0, "measured_at": 0,
         "bytes": position_payload(12, -90.0, -180.0, 0).hex()},
        {"precision": 0, "lat": 90.0, "lon": 180.0,
         "measured_at": 0xFFFFFFFF,
         "bytes": position_payload(0, 90.0, 180.0, 0xFFFFFFFF).hex()},
    ]

    # -------- sealed2 (кодек 5) --------
    tag = sender_tag(pair_key, 20665)
    plain_text_msg = revb_prefix(1786500000, 7, 0, "привет".encode())
    plain_position = revb_prefix(1786525201, 8, 7,
                                 position_payload(0, 10.762622, 106.660172,
                                                  1786525200)[1:])
    # ↑ ВНИМАНИЕ: внутренний кодек уже в префиксе, поэтому данные позиции
    # идут БЕЗ первого байта 0x07 — байт кодека не дублируется.
    sealed_msg = seal2(plain_text_msg, a_priv, b_pub, eph, tag)
    sealed_pos = seal2(plain_position, a_priv, b_pub, eph, tag)
    vectors["sealed2"] = [
        {"a_priv": bytes([0x11] * 32).hex(), "b_priv": bytes([0x22] * 32).hex(),
         "eph_priv": bytes([0x33] * 32).hex(), "tag": tag.hex(),
         "plaintext": plain_text_msg.hex(), "wire": sealed_msg.hex()},
        {"a_priv": bytes([0x11] * 32).hex(), "b_priv": bytes([0x22] * 32).hex(),
         "eph_priv": bytes([0x33] * 32).hex(), "tag": tag.hex(),
         "plaintext": plain_position.hex(), "wire": sealed_pos.hex()},
    ]

    # -------- негативы sealed2 --------
    codec3_wire = seal_v0(b"\x00hello", b_pub, eph, bytes(12))
    tag_flipped = bytearray(sealed_msg)
    tag_flipped[33] ^= 0x01          # байт 33 = первый байт тега
    vectors["sealed2_negative"] = {
        "комментарий": "открытие обязано ПАДАТЬ: чужой домен/ключ/порча",
        "codec3_wire_open2_must_fail": codec3_wire.hex(),
        "sealed2_wire_open_v0_must_fail": sealed_msg.hex(),
        "tag_flipped_wire": bytes(tag_flipped).hex(),
        "wrong_sender_pub": stranger.public_key().public_bytes_raw().hex(),
        "b_priv": bytes([0x22] * 32).hex(),
        "a_pub": a_pub.hex(),
    }

    # -------- session2 (кодек 6) --------
    s2_plain = revb_prefix(1786500060, 9, 0, b"ok")
    vectors["session2"] = [
        {"seed": seed.hex(), "initiator": True, "counter": 0,
         "sent_at": 1786500060, "seq": 9, "inner_codec": 0,
         "data": b"ok".hex(),
         "stream": ratchet_stream(6, seed, True, 0, s2_plain).hex()},
        {"seed": seed.hex(), "initiator": False, "counter": 3,
         "sent_at": 1786500120, "seq": 10, "inner_codec": 7,
         "data": position_payload(0, 0.0, 0.0, 0x01020304)[1:].hex(),
         "stream": ratchet_stream(
             6, seed, False, 3,
             revb_prefix(1786500120, 10, 7,
                         position_payload(0, 0.0, 0.0, 0x01020304)[1:])).hex()},
    ]
    # тот же seed/счётчик/плейнтекст, но кодек 4 в ad: домены 4↔6 —
    # открыватель кодека 6 обязан упасть на этом потоке
    vectors["session4_cross_negative"] = {
        "seed": seed.hex(),
        "stream": ratchet_stream(4, seed, True, 0, s2_plain).hex(),
    }

    # -------- B3: FRAG2 --------
    # Ручной якорь кадра (на бумаге): заголовок 0x23 (ver 2, класс 3),
    # флаги 0x20 (только бит 5), msgID 0x1234 → «34 12», без адреса;
    # блок: index 1 → «01 00», total 300 = 0x012C → «2C 01»,
    # msg_len 2100 = 0x834 → «34 08 00 00»; кусок AB CD.
    якорь = (bytes([V2_TEXT_HEADER0, FLAG_FRAG2]) + le16(0x1234)
             + le16(1) + le16(300) + le32(2100) + b"\xAB\xCD")
    assert якорь.hex() == "2320341201002c0134080000abcd", \
        "якорь FRAG2 разошёлся с бумагой"

    # Полная нарезка: max_payload 20 (гейт по СТАРОЙ нарезке: кусок
    # 20-4-2=14 Б, 3600/14 → 258 кусков > 255 → FRAG2; кусок FRAG2
    # 20-4-8=8 Б → total 450, msg_len 3600)
    поток = bytes((i * 7 + 3) % 256 for i in range(3600))
    кадры = frag2_packets(0x1234, поток, max_payload=20)
    assert len(кадры) == 450 and len(кадры[0]) == 20
    vectors["frag2"] = {
        "msg_id": 0x1234, "want_ack": False, "dst": "",
        "max_payload": 20, "stream": поток.hex(),
        "total": 450, "msg_len": 3600,
        "frames": [f.hex() for f in кадры],
    }
    # Граница гейта: 3570 Б при max_payload 20 — ровно 255 старых
    # кусков → обязана ходить СТАРАЯ нарезка (бит 0, без бита 5)
    vectors["frag2_gate_boundary"] = {
        "max_payload": 20, "stream_len_old_path_max": 3570,
        "комментарий": "255 старых кусков — старый блок u8; "
                       "3571+ Б → 256 кусков → FRAG2",
    }

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "tests", "sealed_revb_vectors.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(vectors, f, ensure_ascii=False, indent=1)
    print("вектора рев B записаны:", out)
    print("sealed2 текст:", len(sealed_msg), "Б провода на",
          len(plain_text_msg), "Б плейнтекста")


if __name__ == "__main__":
    main()
