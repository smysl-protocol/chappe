import Foundation
import CryptoKit

// ============================================================================
// E2ESeal — sealed box поверх payload envelope (веха, фаза 1).
//
// Формат конверта НЕ ломается: шифрованный payload живёт внутри
// существующей рамки как кодек 3 (codecSealed):
//   [3][эфемерный pubkey 32][ChaChaPoly combined: nonce 12 + ct + tag 16]
// Внутри шифртекста — обычный payload ([внутренний кодек][данные]).
// Ключ: X25519(eph, получатель) → HKDF-SHA256 (salt "RM-Smysl-v0",
// info = eph.pub + получатель.pub) → ChaCha20-Poly1305.
//
// SOS НЕ шифруется (решение 24.07) — sealed только для личных классов.
// Паритет с python (sim/e2e_seal.py) — вектора tests/e2e_vectors.json.
// ============================================================================

nonisolated enum E2ESeal {

    static let codecSealed: UInt8 = 3
    static let salt = Data("RM-Smysl-v0".utf8)

    /// Запечатать payload ([внутренний кодек][данные]) для получателя.
    /// ephemeral/nonce инжектируются ТОЛЬКО тест-векторами.
    static func seal(payload: [UInt8],
                     to recipient: Curve25519.KeyAgreement.PublicKey,
                     ephemeral: Curve25519.KeyAgreement.PrivateKey =
                         Curve25519.KeyAgreement.PrivateKey(),
                     nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()) throws
    -> [UInt8] {
        let key = try symmetricKey(private: ephemeral, peer: recipient,
                                   ephPub: ephemeral.publicKey)
        let box = try ChaChaPoly.seal(Data(payload), using: key, nonce: nonce)
        return [codecSealed]
            + Array(ephemeral.publicKey.rawRepresentation)
            + Array(box.combined)
    }

    /// Раскрыть sealed-payload своим приватным ключом. Возвращает
    /// внутренний payload ([кодек][данные]).
    static func open(sealed: [UInt8],
                     identity: Curve25519.KeyAgreement.PrivateKey) throws
    -> [UInt8] {
        guard sealed.count > 1 + 32 + 12 + 16,
              sealed[0] == codecSealed else {
            throw EnvelopeError.malformed("это не sealed-payload")
        }
        let ephPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(sealed[1...32]))
        let key = try symmetricKey(private: identity, peer: ephPub,
                                   ephPub: ephPub)
        let box = try ChaChaPoly.SealedBox(combined: Data(sealed[33...]))
        return Array(try ChaChaPoly.open(box, using: key))
    }

    /// Общий ключ: ECDH → HKDF-SHA256. info = eph.pub + recipient.pub —
    /// у отправителя и получателя совпадает.
    private static func symmetricKey(
        private priv: Curve25519.KeyAgreement.PrivateKey,
        peer: Curve25519.KeyAgreement.PublicKey,
        ephPub: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let shared = try priv.sharedSecretFromKeyAgreement(with: peer)
        // recipient.pub: у отправителя peer = получатель; у получателя
        // peer = eph, а получатель — он сам
        let recipientPub = ephPub == peer
            ? priv.publicKey.rawRepresentation
            : peer.rawRepresentation
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt,
            sharedInfo: ephPub.rawRepresentation + recipientPub,
            outputByteCount: 32)
    }
}

extension Curve25519.KeyAgreement.PublicKey: @retroactive Equatable {
    public static func == (a: Curve25519.KeyAgreement.PublicKey,
                           b: Curve25519.KeyAgreement.PublicKey) -> Bool {
        a.rawRepresentation == b.rawRepresentation
    }
}
