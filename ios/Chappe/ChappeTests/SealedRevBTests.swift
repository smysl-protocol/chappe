import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// Ревизия B (шов docs/reports/wire_revision_b_location_seam.md, подпись
// владельца 11.08): кодеки 5 (sealed2), 6 (session2), 7 (position),
// тег Т1, префикс sent_at+seq, замок счётчика.
//
// Вектора tests/sealed_revb_vectors.json посчитаны НЕЗАВИСИМЫМ
// генератором на сырых примитивах (sim/sealed_revb_vectors_gen.py,
// ручные якоря) — не выводом проверяемого кода. Python-паритет — те же
// вектора (sim/test_envelope.py, TestРевизияB).
// ============================================================================

nonisolated struct SealedRevBTests {

    // MARK: Вектора и помощники

    private func vectors() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/sealed_revb_vectors.json")
        return try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as! [String: Any]
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    private func priv(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(bytes(hex)))
    }

    // MARK: Тег отправителя Т1

    @Test("Тег Т1: HMAC(pairKey, sender-tag+epoch)[0..2] — байты векторов")
    func senderTagParity() throws {
        for v in try vectors()["sender_tags"] as! [[String: Any]] {
            let tag = E2ESeal2.senderTag(
                pairKey: Data(bytes(v["pair_key"] as! String)),
                epoch: v["epoch"] as! Int)
            #expect(tag == bytes(v["tag"] as! String),
                    "тег разошёлся на эпохе \(v["epoch"]!)")
        }
    }

    // MARK: Префикс рев B

    @Test("Префикс: [секунды][seq][кодек][данные] побайтово и обратно")
    func prefixParity() throws {
        for v in try vectors()["prefixes"] as! [[String: Any]] {
            let prefix = RevBPrefix(
                sentAtSeconds: UInt32(v["sent_at"] as! Int),
                seq: UInt32(v["seq"] as! Int),
                innerCodec: UInt8(v["inner_codec"] as! Int),
                data: bytes(v["data"] as! String))
            #expect(prefix.encode() == bytes(v["bytes"] as! String))
            #expect(try RevBPrefix.decode(bytes(v["bytes"] as! String))
                    == prefix)
        }
        #expect(throws: (any Error).self, "короче 9 байт — отказ") {
            _ = try RevBPrefix.decode([1, 2, 3])
        }
    }

    // MARK: Позиция (внутренний кодек 7)

    @Test("Позиция: побайтово из векторов, разбор сходится ре-кодированием")
    func positionParity() throws {
        for v in try vectors()["positions"] as! [[String: Any]] {
            let expected = bytes(v["bytes"] as! String)
            let payload = PositionPayload(
                precision: v["precision"] as! Int,
                lat: v["lat"] as! Double, lon: v["lon"] as! Double,
                measuredAt: UInt32(v["measured_at"] as! Int))
            #expect(try payload.encode() == expected)
            let decoded = try PositionPayload.decode(expected)
            #expect(decoded.precision == payload.precision)
            #expect(decoded.measuredAt == payload.measuredAt)
            // разбор возвращает центр шага сетки §5 — сходимость
            // проверяется ре-кодированием в те же байты
            #expect(try decoded.encode() == expected)
        }
    }

    @Test("Позиция: потолки полей и обрезки — честный отказ")
    func positionCeilings() throws {
        #expect(throws: (any Error).self) {
            _ = try PositionPayload(precision: 13, lat: 0, lon: 0,
                                    measuredAt: 0).encode()
        }
        #expect(throws: (any Error).self) {
            _ = try PositionPayload(precision: 0, lat: 90.1, lon: 0,
                                    measuredAt: 0).encode()
        }
        #expect(throws: (any Error).self) {
            _ = try PositionPayload(precision: 0, lat: 0, lon: -180.1,
                                    measuredAt: 0).encode()
        }
        #expect(throws: (any Error).self) { // обрезок
            _ = try PositionPayload.decode([UInt8](repeating: 0, count: 11))
        }
        #expect(throws: (any Error).self) { // не тот кодек
            _ = try PositionPayload.decode(
                [6, 0] + [UInt8](repeating: 0, count: 10))
        }
    }

    // MARK: sealed2 (кодек 5)

    @Test("sealed2: seal байт в байт с векторами, open возвращает плейнтекст")
    func sealed2Parity() throws {
        for v in try vectors()["sealed2"] as! [[String: Any]] {
            let a = try priv(v["a_priv"] as! String)
            let b = try priv(v["b_priv"] as! String)
            let eph = try priv(v["eph_priv"] as! String)
            let plaintext = bytes(v["plaintext"] as! String)
            let wire = try E2ESeal2.seal(
                plaintext: plaintext, sender: a, to: b.publicKey,
                tag: bytes(v["tag"] as! String), ephemeral: eph)
            #expect(wire == bytes(v["wire"] as! String),
                    "seal2 разошёлся с независимым генератором")
            let opened = try E2ESeal2.open(
                sealed: bytes(v["wire"] as! String), identity: b,
                senderPub: a.publicKey)
            #expect(opened == plaintext)
        }
    }

    @Test("sealed2: домены 3↔5, порча тега, чужой отправитель — падают")
    func sealed2Negatives() throws {
        let n = try vectors()["sealed2_negative"] as! [String: Any]
        let b = try priv(n["b_priv"] as! String)
        let aPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(bytes(n["a_pub"] as! String)))
        let codec3Wire = bytes(n["codec3_wire_open2_must_fail"] as! String)
        let sealed2Wire = bytes(n["sealed2_wire_open_v0_must_fail"] as! String)

        #expect(throws: (any Error).self, "кодек 3 не открывается как 5") {
            _ = try E2ESeal2.open(sealed: codec3Wire, identity: b,
                                  senderPub: aPub)
        }
        #expect(throws: (any Error).self, "sealed2 не открывается как 3") {
            _ = try E2ESeal.open(sealed: sealed2Wire, identity: b)
        }
        // домен НЕ равен байту-роутеру: подделка байта кодека не даёт
        // открыть чужой шифртекст — ключи разведены KDF, падает AEAD
        var forged35 = codec3Wire; forged35[0] = 5
        #expect(throws: (any Error).self) {
            _ = try E2ESeal2.open(sealed: forged35, identity: b,
                                  senderPub: aPub)
        }
        var forged53 = sealed2Wire; forged53[0] = 3
        #expect(throws: (any Error).self) {
            _ = try E2ESeal.open(sealed: forged53, identity: b)
        }
        // тег в ad: порча валит AEAD
        var tagFlipped = sealed2Wire; tagFlipped[33] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try E2ESeal2.open(sealed: tagFlipped, identity: b,
                                  senderPub: aPub)
        }
        // не тот отправитель: второй DH не сходится
        let stranger = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(bytes(n["wrong_sender_pub"] as! String)))
        #expect(throws: (any Error).self) {
            _ = try E2ESeal2.open(sealed: sealed2Wire, identity: b,
                                  senderPub: stranger)
        }
    }

    // MARK: session2 (кодек 6)

    @Test("session2: кадры совпадают с векторами, приём возвращает всё")
    func session2Parity() throws {
        for v in try vectors()["session2"] as! [[String: Any]] {
            let seed = bytes(v["seed"] as! String)
            let initiator = v["initiator"] as! Bool
            let counter = v["counter"] as! Int
            var sender = RatchetEpoch(seed: seed, iAmInitiator: initiator)
            var stream: [UInt8] = []
            for _ in 0...counter {   // прокрутка цепочки до счётчика вектора
                stream = try sender.sealMessage2(
                    innerCodec: UInt8(v["inner_codec"] as! Int),
                    data: bytes(v["data"] as! String),
                    sentAtSeconds: UInt32(v["sent_at"] as! Int),
                    seq: UInt32(v["seq"] as! Int))
            }
            #expect(stream == bytes(v["stream"] as! String),
                    "session2 разошёлся на счётчике \(counter)")

            var receiver = RatchetEpoch(seed: seed, iAmInitiator: !initiator)
            let message = try receiver.openMessage2(stream: stream)
            #expect(message.sentAtSeconds == UInt32(v["sent_at"] as! Int))
            #expect(message.seq == UInt32(v["seq"] as! Int))
            #expect(message.innerCodec == UInt8(v["inner_codec"] as! Int))
            #expect(message.data == bytes(v["data"] as! String))
            // повтор того же кадра — дубль (ветвление радио+релей)
            #expect(throws: RatchetError.duplicate) {
                _ = try receiver.openMessage2(stream: stream)
            }
        }
    }

    @Test("Домены 4↔6: кадр кодека 4 не открывается открывателем 6")
    func session2CrossDomain() throws {
        let n = try vectors()["session4_cross_negative"] as! [String: Any]
        let seed = bytes(n["seed"] as! String)
        var receiver = RatchetEpoch(seed: seed, iAmInitiator: false)
        var stream = bytes(n["stream"] as! String)
        stream[0] = EnvelopeRevB.codecSession2   // подделка байта-роутера
        #expect(throws: (any Error).self,
                "ad коммитит кодек — чужой домен падает на AEAD") {
            _ = try receiver.openMessage2(stream: stream)
        }
    }

    // MARK: Замок счётчика (протокол ревью 11.08, п.4)

    @Test("Счётчик 0xFFFF: отправка невозможна — sessionRefreshNeeded")
    func counterCeiling() throws {
        let seed = (0..<32).map { UInt8($0) }
        var epoch = RatchetEpoch(seed: seed, iAmInitiator: true)
        epoch.sendCounter = 0xFFFF
        do {
            _ = try epoch.sealMessage2(innerCodec: 0, data: [1],
                                       sentAtSeconds: 1, seq: 1)
            Issue.record("отправка на потолке счётчика обязана падать")
        } catch let error as RatchetError {
            guard case .sessionRefreshNeeded = error else {
                Issue.record("не тот отказ: \(error)")
                return
            }
        }
        // до потолка — работает
        epoch.sendCounter = 0xFFFE
        _ = try epoch.sealMessage2(innerCodec: 0, data: [1],
                                   sentAtSeconds: 1, seq: 1)
    }
}
