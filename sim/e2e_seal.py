# -*- coding: utf-8 -*-
"""E2E sealed box — python-зеркало ios/RM/RM/Envelope/E2ESeal.swift.

Формат: [3][eph_pub 32][nonce 12 + ciphertext + tag 16]
Ключ: X25519 → HKDF-SHA256(salt="RM-Smysl-v0", info=eph_pub+recipient_pub).
Запуск как скрипт — перегенерирует tests/e2e_vectors.json.
"""
import json, os
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey, X25519PublicKey)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

CODEC_SEALED = 3
SALT = b"RM-Smysl-v0"

# Ревизия B (шов docs/reports/wire_revision_b_location_seam.md, 11.08):
# кодек 5 sealed2 — тег Т1 вместо полного ключа, второй DH со статикой
# отправителя (анти-спуф по построению), nonce из HKDF (не на проводе).
CODEC_SEALED2 = 5
SALT2 = b"RM-Smysl-v1"


def _key(shared, eph_pub, recipient_pub):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=SALT,
                info=eph_pub + recipient_pub).derive(shared)


def seal(payload, recipient_pub_bytes, eph_priv=None, nonce=None):
    eph = eph_priv or X25519PrivateKey.generate()
    eph_pub = eph.public_key().public_bytes_raw()
    shared = eph.exchange(X25519PublicKey.from_public_bytes(recipient_pub_bytes))
    key = _key(shared, eph_pub, recipient_pub_bytes)
    nonce = nonce or os.urandom(12)
    ct = ChaCha20Poly1305(key).encrypt(nonce, bytes(payload), None)
    return bytes([CODEC_SEALED]) + eph_pub + nonce + ct


def open_sealed(sealed, identity_priv):
    assert sealed[0] == CODEC_SEALED, "не sealed-payload"
    eph_pub = sealed[1:33]
    nonce = sealed[33:45]
    ct = sealed[45:]
    shared = identity_priv.exchange(X25519PublicKey.from_public_bytes(eph_pub))
    recipient_pub = identity_priv.public_key().public_bytes_raw()
    key = _key(shared, eph_pub, recipient_pub)
    return ChaCha20Poly1305(key).decrypt(nonce, ct, None)


def sender_tag(pair_key, epoch):
    """Тег отправителя Т1 (выбор владельца 11.08): вращается по эпохам
    пары. tag = HMAC-SHA256(pairKey, "sender-tag" ‖ epoch u32 LE)[0..2].
    pairKey и эпохи со сдвигом — машинерия MailboxID (общая с dst)."""
    import hashlib
    import hmac
    epoch_le = bytes([epoch & 0xFF, (epoch >> 8) & 0xFF,
                      (epoch >> 16) & 0xFF, (epoch >> 24) & 0xFF])
    return hmac.new(pair_key, b"sender-tag" + epoch_le,
                    hashlib.sha256).digest()[:2]


def _key2(eph_priv, a_priv_or_none, b_pub_bytes, eph_pub, a_pub,
          identity_priv=None):
    """Ключ+nonce sealed2: ikm = DH(eph,B) ‖ DH(A,B), HKDF-SHA256
    (salt v1, info = eph_pub ‖ B_pub ‖ A_pub, 44 Б) -> (key 32, nonce 12).

    Отправитель считает оба DH своими приватными ключами (eph, A);
    получатель — своим приватным B против eph_pub и A_pub.
    """
    b_pub = X25519PublicKey.from_public_bytes(b_pub_bytes)
    if identity_priv is None:                    # сторона отправителя
        ikm = eph_priv.exchange(b_pub) + a_priv_or_none.exchange(b_pub)
    else:                                        # сторона получателя
        ikm = (identity_priv.exchange(X25519PublicKey.from_public_bytes(eph_pub))
               + identity_priv.exchange(X25519PublicKey.from_public_bytes(a_pub)))
    okm = HKDF(algorithm=hashes.SHA256(), length=44, salt=SALT2,
               info=eph_pub + b_pub_bytes + a_pub).derive(ikm)
    return okm[:32], okm[32:]


def seal2(plaintext, sender_priv, recipient_pub_bytes, tag, eph_priv=None):
    """Кодек 5: [0x05][eph_pub 32][tag 2][ct][aead 16].

    ad = [0x05] ‖ eph_pub ‖ tag — порча тега валит AEAD. Анти-спуф:
    второй DH требует приватного ключа отправителя.
    """
    assert len(tag) == 2, "тег отправителя — ровно 2 байта"
    eph = eph_priv or X25519PrivateKey.generate()
    eph_pub = eph.public_key().public_bytes_raw()
    a_pub = sender_priv.public_key().public_bytes_raw()
    key, nonce = _key2(eph, sender_priv, recipient_pub_bytes, eph_pub, a_pub)
    ad = bytes([CODEC_SEALED2]) + eph_pub + bytes(tag)
    ct = ChaCha20Poly1305(key).encrypt(nonce, bytes(plaintext), ad)
    return bytes([CODEC_SEALED2]) + eph_pub + bytes(tag) + ct


def open2(sealed, identity_priv, sender_pub_bytes):
    """Открыть кадр кодека 5 от заявленного (тегом) отправителя.

    Кандидатов с совпавшим тегом может быть несколько — вызывающий
    пробует каждого; не тот ключ не расшифруется (AEAD).
    """
    if len(sealed) < 1 + 32 + 2 + 16 or sealed[0] != CODEC_SEALED2:
        raise ValueError("это не sealed2-кадр")
    eph_pub = bytes(sealed[1:33])
    tag = bytes(sealed[33:35])
    recipient_pub = identity_priv.public_key().public_bytes_raw()
    key, nonce = _key2(None, None, recipient_pub, eph_pub,
                       bytes(sender_pub_bytes), identity_priv=identity_priv)
    ad = bytes([CODEC_SEALED2]) + eph_pub + tag
    return ChaCha20Poly1305(key).decrypt(nonce, bytes(sealed[35:]), ad)


if __name__ == "__main__":
    # Детерминированные вектора для Swift-паритета
    vectors = []
    for i, text in enumerate([
        b"\x00hello smysl",                    # store-кодек внутри
        b"\x02" + bytes(range(40)),            # semantic-blob внутри
        "\x00Привет, узел!".encode("utf-8"),
    ]):
        recipient = X25519PrivateKey.from_private_bytes(bytes([i + 1] * 32))
        eph = X25519PrivateKey.from_private_bytes(bytes([100 + i] * 32))
        nonce = bytes([i] * 12)
        sealed = seal(text, recipient.public_key().public_bytes_raw(),
                      eph_priv=eph, nonce=nonce)
        assert open_sealed(sealed, recipient) == text
        vectors.append({
            "recipient_priv": (bytes([i + 1] * 32)).hex(),
            "eph_priv": (bytes([100 + i] * 32)).hex(),
            "nonce": nonce.hex(),
            "payload": text.hex(),
            "sealed": sealed.hex(),
        })
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "tests", "e2e_vectors.json")
    json.dump({"vectors": vectors}, open(out, "w"), indent=1)
    print("вектора зелёные и записаны:", len(vectors))
