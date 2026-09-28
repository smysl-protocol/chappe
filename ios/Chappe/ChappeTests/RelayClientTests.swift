import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// Релейный путь (05.08): box-ключ эпохи, окно эпох, таблица исходов,
// потолок повторов.
//
// Главный замок — кросс-вектор с Go-реализацией релея: ожидания ниже
// СГЕНЕРИРОВАНЫ rm-relay/internal/boxkey (04.08, команда в комментарии),
// не этим кодом. Разъедутся порядок полей, разделитель или формат
// подписи — тест покраснеет, а не «подпись не сходится» в поле.
// ============================================================================

nonisolated struct RelayBoxKeyTests {

    // Вектора: rm-relay, временный TestPrintCrossVectors поверх
    // internal/boxkey (Derive + Sign), 04.08.2026:
    //   recipient = 01..20 (32 байта), pairKey = a0..af ×2, epoch 19942
    //   nonce = 40..5f, issued_at = 1754300000
    static let recipient = Data((1...32).map { UInt8($0) })
    static let pairKey = Data((0..<32).map { UInt8(0xA0 + $0 % 16) })
    static let epoch = 19942
    static let goPublicHex =
        "ca2942b9435464d4cfe2601f797e6c7f39f8d00d54ae7d69e090581f7cb859d2"
    static let goSigHex =
        "b56f381fa8814a8a6ff2ea299bddfbcbd5c9d3a954b47f33f29bd60fdc5fe20e"
        + "ad3ff0c2c557a1bbba817c08f7db6e17b917955058a9b8e90fdeaf0881cddf07"

    @Test("вывод ключа ящика побайтово совпадает с Go-реализацией релея")
    func deriveMatchesGo() {
        let key = RelayBoxKey.derive(recipientPub: Self.recipient,
                                     pairKey: Self.pairKey,
                                     epoch: Self.epoch)
        let pubHex = key.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        #expect(pubHex == Self.goPublicHex)
    }

    @Test("подпись Go проходит под нашим ключом над нашими данными подписи")
    func challengeSignatureMatchesGo() throws {
        // CryptoKit подписывает рандомизированно (hedged Ed25519),
        // побайтового равенства подписей не бывает. Замок в другую
        // сторону: ПОДПИСЬ GO обязана проходить проверку под ключом,
        // выведенным Swift'ом, над данными, собранными Swift'ом.
        // Разойдись вывод ключа или формат данных — проверка упадёт.
        let key = RelayBoxKey.derive(recipientPub: Self.recipient,
                                     pairKey: Self.pairKey,
                                     epoch: Self.epoch)
        let nonce = Data((0..<32).map { UInt8(0x40 + $0) })
        let data = RelayBoxKey.challengeData(nonce: nonce,
                                             issuedAt: 1_754_300_000)
        let goSig = Data(stride(from: 0, to: Self.goSigHex.count, by: 2).map {
            let s = Self.goSigHex.index(Self.goSigHex.startIndex, offsetBy: $0)
            let e = Self.goSigHex.index(s, offsetBy: 2)
            return UInt8(Self.goSigHex[s..<e], radix: 16)!
        })
        #expect(key.publicKey.isValidSignature(goSig, for: data),
                "подпись Go не прошла — конверт подписи разошёлся с релеем")
        // и обратно: наша подпись валидна под нашим же ключом
        let ours = try RelayBoxKey.signChallenge(key: key, nonce: nonce,
                                                 issuedAt: 1_754_300_000)
        #expect(key.publicKey.isValidSignature(ours, for: data))
    }
}

// ============================================================================
// Окно эпох: граница псевдослучайна (HMAC от ключа пары) — клиент
// обязан попадать в приёмное окно и на смене эпохи ничего не терять.
// ============================================================================

nonisolated struct RelayEpochWindowTests {

    /// Отправитель считает dst по СВОИМ часам; получатель проверяет
    /// своим окном. Часы расходятся до суток — dst обязан попадать
    /// в окно всегда, включая моменты вплотную к границе эпохи.
    @Test("dst отправителя попадает в окно получателя при расхождении часов",
          arguments: [-24 * 3600.0, -3600, -60, 0, 60, 3600, 24 * 3600])
    func senderDstInsideReceiverWindow(skew: Double) {
        let pairKey = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
        let myPub = Data((0..<32).map { UInt8($0 &+ 100) })
        // моменты вокруг нескольких границ эпох, включая ±1 секунду
        let base = Date(timeIntervalSince1970: 1_754_300_000)
        var moments: [Date] = [base]
        for epoch in 20303...20305 {
            let boundary = MailboxID.boundary(pairKey: pairKey, epoch: epoch)
            moments.append(Date(timeIntervalSince1970: boundary - 1))
            moments.append(Date(timeIntervalSince1970: boundary + 1))
        }
        for sendMoment in moments {
            let dst = MailboxID.dstForSending(recipientPub: myPub,
                                              pairKey: pairKey,
                                              now: sendMoment)
            let receiverNow = sendMoment.addingTimeInterval(skew)
            #expect(MailboxID.isMine(dst, myPub: myPub, pairKey: pairKey,
                                     now: receiverNow),
                    "dst выпал из окна: отправка \(sendMoment), сдвиг \(skew)")
        }
    }

    /// Box-ключ и dst выводятся из ОДНИХ данных: для каждой эпохи окна
    /// ключ, выведенный получателем, совпадает с ключом отправителя.
    @Test("box-ключ обеих сторон совпадает на каждой эпохе окна")
    func boxKeySymmetric() {
        let pairKey = Data((0..<32).map { UInt8($0 &+ 11) })
        let recipientPub = Data((0..<32).map { UInt8($0 &+ 200) })
        for epoch in MailboxID.acceptedEpochs(pairKey: pairKey) {
            let sender = RelayBoxKey.derive(recipientPub: recipientPub,
                                            pairKey: pairKey, epoch: epoch)
            let receiver = RelayBoxKey.derive(recipientPub: recipientPub,
                                              pairKey: pairKey, epoch: epoch)
            #expect(sender.publicKey.rawRepresentation
                    == receiver.publicKey.rawRepresentation)
        }
    }
}

// ============================================================================
// Таблица исходов PUT: каждый код — своё поведение и своя строка.
// ============================================================================

nonisolated struct RelayOutcomeTests {

    static let allOutcomes: [RelayClient.PutOutcome] = [
        .stored(duplicate: false), .stored(duplicate: true),
        .expiredUndelivered, .boxFull, .tooLarge, .badFrame,
        .foreignKey, .rateLimited(retryAfter: 60), .storageDown,
        .serverError, .unreachable,
    ]

    @Test("у каждого исхода — своя строка человеку, не «ошибка отправки»")
    func everyOutcomeHasDistinctHumanText() {
        var seen = Set<String>()
        for outcome in Self.allOutcomes.dropFirst() {   // dup-вариант неотличим и не должен
            #expect(!outcome.human.isEmpty)
            #expect(outcome.human != "ошибка отправки")
            seen.insert(outcome.human)
        }
        #expect(seen.count == Self.allOutcomes.count - 1,
                "строки исходов совпали — человек не отличит причины")
    }

    @Test("повторяемость исходов: терминальные не повторяются, временные повторяются")
    func retrySemantics() {
        // Внешнее ожидание — таблица relay_ops.md §WP4.2:
        // 410/400/413 «не повторять», 507/503/429 «повторить позже»,
        // таймаут — «неизвестно» → повторить.
        #expect(!RelayClient.PutOutcome.expiredUndelivered.retryable)
        #expect(!RelayClient.PutOutcome.badFrame.retryable)
        #expect(!RelayClient.PutOutcome.tooLarge.retryable)
        #expect(RelayClient.PutOutcome.boxFull.retryable)
        #expect(RelayClient.PutOutcome.storageDown.retryable)
        #expect(RelayClient.PutOutcome.rateLimited(retryAfter: 1).retryable)
        #expect(RelayClient.PutOutcome.unreachable.retryable)
    }
}

// ============================================================================
// Размеры провода по релею — против docs/reports/envelope_v2_measured.md:
// «ок» (смысл 4 Б) по релею 44 Б, отель (смысл 35 Б) — 75 Б. Литералы —
// из отчёта замеров, не из этого кода.
// ============================================================================

nonisolated struct RelayWireSizeTests {

    private func relayFrameSize(payloadLength: Int) throws -> Int {
        var epoch = RatchetEpoch(seed: Array(repeating: 7, count: 32),
                                 iAmInitiator: true)
        let stream = try epoch.sealMessage(
            innerCodec: Envelope.codecStore,
            data: Array(repeating: 0x41, count: payloadLength),
            sentAtMinutes: 29_238_333)
        let dst = Array(repeating: UInt8(0xD1), count: 8)
        let frames = try EnvelopeV2.encodePackets(
            msgID: 0x0201, stream: stream, dst: dst)
        #expect(frames.count == 1)
        return frames[0].count
    }

    @Test("«ок» по релею — 44 байта, как в замерах v2")
    func okViaRelayIs44() throws {
        #expect(try relayFrameSize(payloadLength: 4) == 44)
    }

    @Test("отель по релею — 75 байт, как в замерах v2")
    func hotelViaRelayIs75() throws {
        #expect(try relayFrameSize(payloadLength: 35) == 75)
    }
}

// ============================================================================
// Потолок повторов (WP3): 890 и 1149 попыток из полевых логов 03.08 —
// больше не случатся.
// ============================================================================

nonisolated struct RetryCeilingTests {

    @Test("потолок существует и меньше наблюдавшихся 890 попыток")
    func ceilingBelowFieldObservations() {
        // 890 и 1149 — литералы из handoff 03.08 §4 п.1 (полевой лог),
        // внешнее ожидание: потолок обязан быть радикально ниже
        #expect(DeliveryManager.maxAttempts < 890 / 4)
        #expect(DeliveryManager.maxAttempts > 0)
    }
}
