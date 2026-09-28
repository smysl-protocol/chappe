import Foundation
import CryptoKit
import Testing
@testable import Chappe

// ============================================================================
// WP0/WP2/WP3 (Envelope v2, 02.08): каркас формата, суточный dst с
// окном на границе суток, совместимость v1↔v2, golden vectors.
// ============================================================================

nonisolated struct EnvelopeV2Tests {

    // MARK: WP0 — каркас

    @Test("радио: флага адреса нет, блок не занимает ни байта")
    func radioFrameHasNoAddress() throws {
        let stream: [UInt8] = [EnvelopeV2.codecSession] + Array(repeating: 9, count: 30)
        let packets = try EnvelopeV2.encodePackets(msgID: 0x1234, stream: stream)
        #expect(packets.count == 1)
        #expect(packets[0].count == 4 + stream.count, "рамка = только заголовок")
        #expect(packets[0][1] & EnvelopeV2.flagHasAddress == 0)
        let frame = try EnvelopeV2.decode(packets[0])
        #expect(frame.dst == nil)
        #expect(frame.stream == stream)
        #expect(frame.msgID == 0x1234)
    }

    @Test("релей: dst 8 Б под флагом, разбирается обратно")
    func relayFrameCarriesDst() throws {
        let dst = Array<UInt8>(1...8)
        let stream: [UInt8] = [EnvelopeV2.codecSession, 0xAA]
        let packets = try EnvelopeV2.encodePackets(msgID: 7, stream: stream,
                                                   dst: dst)
        #expect(packets[0].count == 4 + 8 + stream.count)
        #expect(packets[0][1] & EnvelopeV2.flagHasAddress != 0)
        let frame = try EnvelopeV2.decode(packets[0])
        #expect(frame.dst == dst)
        #expect(frame.stream == stream)
    }

    @Test("фрагментация v2: собирается обратно побайтово")
    func fragmentationRoundTrip() throws {
        let stream = [EnvelopeV2.codecSession] + (0..<400).map { UInt8($0 % 251) }
        let packets = try EnvelopeV2.encodePackets(msgID: 3, stream: stream,
                                                   dst: Array(repeating: 5, count: 8))
        #expect(packets.count > 1)
        var chunks: [Int: [UInt8]] = [:]
        var total = 0
        for packet in packets {
            let frame = try EnvelopeV2.decode(packet)
            #expect(frame.dst?.count == 8, "адрес в каждом пакете — релей маршрутизирует пакеты")
            let fragment = try #require(frame.fragment)
            chunks[fragment.index] = frame.stream
            total = fragment.total
        }
        let assembled = (0..<total).compactMap { chunks[$0] }.flatMap { $0 }
        #expect(assembled == stream)
    }

    @Test("СТОП-УСЛОВИЕ: отправитель не выводится из открытых полей")
    func senderIsNotDerivableFromWire() throws {
        let seed = (0..<32).map { UInt8($0 &+ 3) }
        var alice = RatchetEpoch(seed: seed, iAmInitiator: true)
        let myPub = Curve25519.KeyAgreement.PrivateKey().publicKey
            .rawRepresentation
        let stream = try alice.sealMessage(innerCodec: Envelope.codecStore,
                                           data: Array("секрет".utf8),
                                           sentAtMinutes: 12345)
        let dst = MailboxID.dstForSending(
            recipientPub: myPub,
            pairKey: Data(repeating: 0x5A, count: 32))
        let packet = try EnvelopeV2.encodePackets(msgID: 42, stream: stream,
                                                  dst: dst)[0]

        // 1) байтов ключа отправителя на проводе нет
        #expect(!contains(packet, Array(myPub)))
        // 2) и вообще ни одно открытое поле не совпадает с чем-либо,
        // производным от отправителя без ключа сессии
        let frame = try EnvelopeV2.decode(packet)
        let openFields: [[UInt8]] = [[packet[0]], [packet[1]],
                                     Array(packet[2...3]),
                                     frame.dst ?? [],
                                     Array(frame.stream.prefix(7))]
        let senderDerived: [[UInt8]] = [
            Array(myPub),
            Array(Data(SHA256.hash(data: myPub)).prefix(8)),
            Array(Data(SHA256.hash(data: myPub)).prefix(4)),
        ]
        for field in openFields {
            for derived in senderDerived {
                #expect(field != derived,
                        "открытое поле совпало с производной отправителя")
            }
        }
        // 3) метки времени в открытом виде тоже нет (№5)
        let ts: [UInt8] = [0x39, 0x30, 0x00, 0x00]      // 12345 LE
        #expect(!contains(packet, ts))
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }

    // MARK: WP2 — псевдоним ящика (с 04.08 — эпохи пары со сдвигом;
    // подробности и граничные случаи — MailboxEpochTests)

    /// Ключ пары в тестах фиксирован — вектора воспроизводимы.
    private static let testPairKey = Data(repeating: 0x5A, count: 32)

    @Test("dst меняется от эпохи к эпохе")
    func dstRotatesByEpoch() {
        let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let epoch = MailboxID.epoch(pairKey: Self.testPairKey, at: Date())
        #expect(MailboxID.dst(recipientPub: pub, pairKey: Self.testPairKey,
                              epoch: epoch)
                != MailboxID.dst(recipientPub: pub, pairKey: Self.testPairKey,
                                 epoch: epoch + 1))
        #expect(MailboxID.dst(recipientPub: pub, pairKey: Self.testPairKey,
                              epoch: epoch).count == 8)
    }

    @Test("СТОП-УСЛОВИЕ: на границе эпохи сообщения не теряются",
          arguments: [-6.0, -3.0, -1.0, 1.0, 3.0, 6.0])
    func dstSurvivesClockSkewAcrossBoundary(skewHours: Double) {
        let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let epochNow = MailboxID.epoch(pairKey: Self.testPairKey, at: Date())
        let edge = Date(timeIntervalSince1970:
            MailboxID.boundary(pairKey: Self.testPairKey, epoch: epochNow))
        for offset in [-120.0, -1.0, 0.0, 1.0, 120.0] {   // ±2 мин от границы
            let receiverNow = edge.addingTimeInterval(offset)
            let senderNow = receiverNow.addingTimeInterval(skewHours * 3600)
            let sent = MailboxID.dstForSending(recipientPub: pub,
                                               pairKey: Self.testPairKey,
                                               now: senderNow)
            #expect(MailboxID.isMine(sent, myPub: pub,
                                     pairKey: Self.testPairKey,
                                     now: receiverNow),
                    "сдвиг \(skewHours) ч у границы эпохи потерял сообщение")
        }
    }

    @Test("релейное окно покрывает 48 ч хранения назад")
    func dstWindowCoversRelayStorage() {
        let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let now = Date()
        for hoursAgo in [1.0, 24.0, 47.0] {
            let sent = MailboxID.dstForSending(
                recipientPub: pub, pairKey: Self.testPairKey,
                now: now.addingTimeInterval(-hoursAgo * 3600))
            #expect(MailboxID.isMine(sent, myPub: pub,
                                     pairKey: Self.testPairKey, now: now),
                    "сообщение из ящика \(hoursAgo) ч назад не опознано")
        }
    }

    @Test("чужой dst не принимается за свой")
    func foreignDstRejected() {
        let mine = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let sent = MailboxID.dstForSending(recipientPub: other,
                                           pairKey: Self.testPairKey)
        #expect(!MailboxID.isMine(sent, myPub: mine,
                                  pairKey: Self.testPairKey))
    }

    // MARK: WP3 — совместимость версий

    @Test("СТОП-УСЛОВИЕ: приёмник v1 отвергает v2 явно, без мусора")
    func v1RejectsV2Cleanly() throws {
        let packet = try EnvelopeV2.encodePackets(
            msgID: 1, stream: [EnvelopeV2.codecSession, 1, 2, 3])[0]
        // ровно то, что делает старый бинарник на первом же шаге
        do {
            _ = try Envelope.decodeHeader(packet)
            Issue.record("v1 обязан отвергнуть v2-пакет")
        } catch let error as EnvelopeError {
            #expect(error.errorDescription?.contains("версия") == true,
                    "причина отказа обязана быть понятной")
        }
        // и полный разбор тоже не отдаёт мусор
        #expect(throws: (any Error).self) { _ = try EnvelopeDecoder.decode(packet) }
    }

    @Test("приёмник v2 нормально читает пакет v1")
    func v2ReadsV1() throws {
        let packets = try TextEncoder.encode(msgID: 5, text: "старый формат",
                                             codec: Envelope.codecStore,
                                             sentAtMinutes: 777)
        let decoded = try EnvelopeDecoder.decode(packets[0])
        guard case .text(let message) = decoded else {
            Issue.record("v1-пакет обязан разбираться как TEXT")
            return
        }
        #expect(message.text == "старый формат")
        #expect(message.sentAtMinutes == 777)
        // и v2-разборщик его НЕ перехватывает
        #expect(throws: (any Error).self) { _ = try EnvelopeV2.decode(packets[0]) }
    }

    @Test("деградация: без подтверждения v2 отправка идёт v1")
    func degradesToV1UntilPeerConfirms() {
        let seed = (0..<32).map { UInt8($0) }
        let epoch = RatchetEpoch(seed: seed, iAmInitiator: true)
        #expect(!epoch.peerConfirmedV2,
                "новая эпоха не подтверждена — исходящие обязаны идти v1")
    }

    // MARK: Golden vectors — формат не должен поплыть незаметно

    @Test("golden: v1-пакет побайтово стабилен")
    func goldenV1() throws {
        let packets = try TextEncoder.encode(msgID: 0x0102, text: "ok",
                                             codec: Envelope.codecStore,
                                             sentAtMinutes: 0x03040506)
        #expect(hex(packets[0]) == "1300020106050403006f6b")
    }

    @Test("golden: v2-рамка побайтово стабильна (радио и релей)")
    func goldenV2Frame() throws {
        let stream: [UInt8] = [EnvelopeV2.codecSession, 0xAA, 0xBB]
        let radio = try EnvelopeV2.encodePackets(msgID: 0x0102, stream: stream)[0]
        // [ver2|classText=0x23][flags][msgID LE][(dst 8)][поток]
        #expect(hex(radio) == "2300020104aabb")

        let relay = try EnvelopeV2.encodePackets(
            msgID: 0x0102, stream: stream,
            dst: [0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8])[0]
        #expect(hex(relay) == "23100201d1d2d3d4d5d6d7d804aabb")
    }

    @Test("golden: dst эпохи воспроизводим по фиксированным входам")
    func goldenDst() {
        // САНКЦИОНИРОВАННАЯ СМЕНА ЭТАЛОНА (решение владельца 04.08).
        // Было: SHA-256(pub ‖ день)[0..8] = 52eb66e476e8d686 — граница
        // суток в полночь UTC. Стало: SHA-256(pub ‖ ключ пары ‖ эпоха)
        // с псевдослучайным сдвигом границы (MailboxID). Причина —
        // постоянная фаза ротации была бы отпечатком пары, а полночь
        // UTC рвала человеческий день в Азии (docs/relay_privacy.md).
        // Сущность 6 FREEZE изменена сознательно, пока сеть = одна пара.
        // Эталон посчитан python вне приложения (внешнее ожидание).
        let pub = Data(repeating: 0x2A, count: 32)
        let pairKey = Data(repeating: 0x5A, count: 32)
        #expect(hex(MailboxID.dst(recipientPub: pub, pairKey: pairKey,
                                  epoch: 20000))
                == "59ae83f55101efb4")
        #expect(MailboxID.dst(recipientPub: pub, pairKey: pairKey,
                              epoch: 20000)
                != MailboxID.dst(recipientPub: pub, pairKey: pairKey,
                                 epoch: 20001))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

