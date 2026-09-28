import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Веха, фаза 1: sealed box (X25519 + HKDF + ChaChaPoly) — паритет с
// python-эталоном (sim/e2e_seal.py, вектора tests/e2e_vectors.json)
// байт в байт; roundtrip; отпечаток узла.
// ============================================================================

nonisolated struct E2ESealTests {

    private func vectors() throws -> [[String: String]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/e2e_vectors.json")
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
        return json["vectors"] as! [[String: String]]
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    @Test("Паритет с python: seal байт в байт, open возвращает payload")
    func parityWithPython() throws {
        for v in try vectors() {
            let recipient = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(bytes(v["recipient_priv"]!)))
            let ephemeral = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(bytes(v["eph_priv"]!)))
            let nonce = try ChaChaPoly.Nonce(data: Data(bytes(v["nonce"]!)))
            let payload = bytes(v["payload"]!)

            let sealed = try E2ESeal.seal(payload: payload,
                                          to: recipient.publicKey,
                                          ephemeral: ephemeral, nonce: nonce)
            #expect(sealed == bytes(v["sealed"]!), "seal разошёлся с python")

            let opened = try E2ESeal.open(sealed: bytes(v["sealed"]!),
                                          identity: recipient)
            #expect(opened == payload, "open не вернул исходный payload")
        }
    }

    @Test("Roundtrip со случайными ключами; чужой ключ не открывает")
    func roundtripAndWrongKey() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let payload: [UInt8] = [2] + Array("smysl blob".utf8)
        let sealed = try E2ESeal.seal(payload: payload,
                                      to: recipient.publicKey)
        #expect(try E2ESeal.open(sealed: sealed, identity: recipient) == payload)
        // размер: +61 Б к payload (кодек 1 + eph 32 + nonce 12 + tag 16)
        #expect(sealed.count == payload.count + 61)

        let stranger = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: (any Error).self) {
            _ = try E2ESeal.open(sealed: sealed, identity: stranger)
        }
    }

    @Test("Отпечаток узла: 8 символов base32, стабилен, различает ключи")
    func fingerprintProperties() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey
        let fa = Identity.fingerprint(of: a)
        #expect(fa.count == 8)
        #expect(fa.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) })
        #expect(fa == Identity.fingerprint(of: a), "стабилен")
        #expect(fa != Identity.fingerprint(of: b), "различает ключи")
    }
}
