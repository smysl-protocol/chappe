import Foundation
import CryptoKit

// ============================================================================
// Ревизия B конверта (шов docs/reports/wire_revision_b_location_seam.md,
// подпись владельца 11.08.2026; тег — вариант Т1).
//
// Кодеки потока: 5 sealed2 (запечатанный кадр известной паре, тег 2 Б
// вместо полного ключа 32 Б), 6 session2 (рэтчет Б с префиксом рев B),
// 7 position (ВНУТРЕННИЙ кодек: нагрузка — позиция, не текст).
//
// Общий префикс плейнтекста 5/6: [sent_at unix-СЕКУНДЫ u32 LE][seq u32
// LE][внутренний кодек][данные]. Порядок ленты держит seq (монотонный
// счётчик пары), sent_at — косметика показа: часы отправителя доказанно
// врут (полевое 10.08). Позиция со старым seq отбрасывается приёмником.
//
// Кодек 3 (E2ESeal) ЗАМОРОЖЕН: рукопожатие и первый кадр новой пары
// несут полный ключ (шов B2 — автодопуск сверяет ключ с отпечатком).
// Домены 3↔5 разведены KDF (соль v0↔v1, разный состав ikm), 4↔6 —
// байтом кодека в ad; переинтерпретация падает на AEAD по построению.
//
// Паритет: sim/envelope.py + sim/e2e_seal.py; вектора
// tests/sealed_revb_vectors.json — независимый генератор, не вывод кода.
// ============================================================================

nonisolated enum EnvelopeRevB {
    /// Запечатанный кадр известной паре (сессии ещё нет).
    static let codecSealed2: UInt8 = 5
    /// Кадр эпохи рэтчета с префиксом рев B (вытесняет отправку кодека 4).
    static let codecSession2: UInt8 = 6
    /// Внутренний кодек: полезная нагрузка — позиция (внутри AEAD 5/6).
    static let codecPosition: UInt8 = 7

    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    static func readLE32(_ b: ArraySlice<UInt8>) -> UInt32 {
        let a = Array(b)
        return UInt32(a[0]) | UInt32(a[1]) << 8
            | UInt32(a[2]) << 16 | UInt32(a[3]) << 24
    }
}

// MARK: - Общий префикс плейнтекста кодеков 5 и 6

nonisolated struct RevBPrefix: Equatable {
    var sentAtSeconds: UInt32
    var seq: UInt32
    var innerCodec: UInt8
    var data: [UInt8]

    func encode() -> [UInt8] {
        EnvelopeRevB.le32(sentAtSeconds) + EnvelopeRevB.le32(seq)
            + [innerCodec] + data
    }

    static func decode(_ stream: [UInt8]) throws -> RevBPrefix {
        guard stream.count >= 9 else {
            throw EnvelopeError.tooShort(
                "префикс рев B: нужно ≥9 байт, получено \(stream.count)")
        }
        return RevBPrefix(sentAtSeconds: EnvelopeRevB.readLE32(stream[0..<4]),
                          seq: EnvelopeRevB.readLE32(stream[4..<8]),
                          innerCodec: stream[8],
                          data: Array(stream.dropFirst(9)))
    }
}

// MARK: - Позиция (внутренний кодек 7)

/// [0x07][precision 1][lat 3 LE][lon 3 LE][measured_at u32 LE] = 12 Б.
/// Координаты — канон Envelope §5 fine, второго формата в проекте нет.
/// precision: 0 = exact, 1–12 = длина ячейки геохеша загрубления
/// (координата обязана быть уже центром ячейки — загрубляет дверь WP4
/// ДО конверта, из байтов точность не восстановить).
nonisolated struct PositionPayload: Equatable {
    static let size = 12

    var precision: Int
    var lat: Double
    var lon: Double
    /// Когда позиция ИЗМЕРЕНА (не отправлена): событийная модель шлёт
    /// последний фикс. Будущее приёмник клэмпит к своему now.
    var measuredAt: UInt32

    func encode() throws -> [UInt8] {
        guard (0...12).contains(precision) else {
            throw EnvelopeError.badValue(
                "precision = \(precision), а допустимо 0…12")
        }
        return [EnvelopeRevB.codecPosition, UInt8(precision)]
            + (try Envelope.encodeFineCoords(lat: lat, lon: lon))
            + EnvelopeRevB.le32(measuredAt)
    }

    static func decode(_ data: [UInt8]) throws -> PositionPayload {
        guard data.count == size else {
            throw EnvelopeError.tooShort(
                "позиция: нужно ровно \(size) байт, получено \(data.count)")
        }
        guard data[0] == EnvelopeRevB.codecPosition else {
            throw EnvelopeError.badValue(
                "это не позиция: кодек \(data[0])")
        }
        guard (0...12).contains(Int(data[1])) else {
            throw EnvelopeError.badValue("precision = \(data[1]) вне 0…12")
        }
        let (lat, lon) = Envelope.decodeFineCoords(data[2..<8])
        return PositionPayload(precision: Int(data[1]), lat: lat, lon: lon,
                               measuredAt: EnvelopeRevB.readLE32(data[8..<12]))
    }
}

// MARK: - sealed2 (кодек 5)

/// [0x05][eph_pub 32][sender_tag 2][ct][aead 16]; nonce на проводе НЕТ —
/// ключ уникален на кадр (эфемерка), key и nonce выводятся HKDF.
///
/// ikm = DH(eph, B) ‖ DH(A, B) — второй DH со СТАТИКОЙ отправителя:
/// собрать кадр «от имени» A без приватного ключа A нельзя, AEAD не
/// сойдётся (анти-спуф по построению, сильнее замороженного кодека 3).
/// ad = [0x05] ‖ eph_pub ‖ tag — порча тега валит AEAD.
nonisolated enum E2ESeal2 {

    static let salt = Data("RM-Smysl-v1".utf8)
    /// Обвязка кадра: кодек 1 + eph 32 + тег 2 + AEAD-тег 16.
    static let overhead = 1 + 32 + 2 + 16

    /// Тег отправителя Т1 (выбор владельца 11.08): вращается по эпохам
    /// пары — tag = HMAC(pairKey, "sender-tag" ‖ epoch u32 LE)[0..2].
    /// pairKey и эпохи со сдвигом границы — машинерия MailboxID (общая
    /// с dst): наблюдатель не связывает кадры между сутками.
    static func senderTag(pairKey: Data, epoch: Int) -> [UInt8] {
        var input = Data("sender-tag".utf8)
        input.append(contentsOf: EnvelopeRevB.le32(UInt32(clamping: epoch)))
        let mac = HMAC<SHA256>.authenticationCode(
            for: input, using: SymmetricKey(data: pairKey))
        return Array(Data(mac).prefix(2))
    }

    /// Запечатать плейнтекст (уже с префиксом рев B) известной паре.
    /// ephemeral инжектируется ТОЛЬКО тест-векторами.
    static func seal(plaintext: [UInt8],
                     sender: Curve25519.KeyAgreement.PrivateKey,
                     to recipient: Curve25519.KeyAgreement.PublicKey,
                     tag: [UInt8],
                     ephemeral: Curve25519.KeyAgreement.PrivateKey =
                         Curve25519.KeyAgreement.PrivateKey()) throws
    -> [UInt8] {
        guard tag.count == 2 else {
            throw EnvelopeError.badValue("тег отправителя — ровно 2 байта")
        }
        let ephPub = ephemeral.publicKey.rawRepresentation
        let dhEph = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let dhStatic = try sender.sharedSecretFromKeyAgreement(with: recipient)
        let ikm = dhEph.withUnsafeBytes { Data($0) }
            + dhStatic.withUnsafeBytes { Data($0) }
        let (key, nonce) = keyAndNonce(
            ikm: ikm, ephPub: ephPub,
            recipientPub: recipient.rawRepresentation,
            senderPub: sender.publicKey.rawRepresentation)
        let ad = [EnvelopeRevB.codecSealed2] + Array(ephPub) + tag
        let box = try ChaChaPoly.seal(Data(plaintext), using: key,
                                      nonce: nonce,
                                      authenticating: Data(ad))
        return ad + Array(box.ciphertext + box.tag)
    }

    /// Открыть кадр от ЗАЯВЛЕННОГО (тегом) отправителя. Кандидатов с
    /// совпавшим тегом может быть несколько — вызывающий пробует
    /// каждого; не тот ключ не расшифруется (AEAD разруливает).
    static func open(sealed: [UInt8],
                     identity: Curve25519.KeyAgreement.PrivateKey,
                     senderPub: Curve25519.KeyAgreement.PublicKey) throws
    -> [UInt8] {
        guard sealed.count > overhead,
              sealed[0] == EnvelopeRevB.codecSealed2 else {
            throw EnvelopeError.malformed("это не sealed2-кадр")
        }
        let ephPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(sealed[1...32]))
        let dhEph = try identity.sharedSecretFromKeyAgreement(with: ephPub)
        let dhStatic = try identity.sharedSecretFromKeyAgreement(with: senderPub)
        let ikm = dhEph.withUnsafeBytes { Data($0) }
            + dhStatic.withUnsafeBytes { Data($0) }
        let (key, nonce) = keyAndNonce(
            ikm: ikm, ephPub: ephPub.rawRepresentation,
            recipientPub: identity.publicKey.rawRepresentation,
            senderPub: senderPub.rawRepresentation)
        let ad = Array(sealed.prefix(35))
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: Data(sealed.dropFirst(35).dropLast(16)),
            tag: Data(sealed.suffix(16)))
        return Array(try ChaChaPoly.open(box, using: key,
                                         authenticating: Data(ad)))
    }

    /// HKDF-SHA256(salt v1, info = eph ‖ B ‖ A, 44 Б) → key 32 ‖ nonce 12.
    private static func keyAndNonce(ikm: Data, ephPub: Data,
                                    recipientPub: Data, senderPub: Data)
    -> (SymmetricKey, ChaChaPoly.Nonce) {
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
            info: ephPub + recipientPub + senderPub, outputByteCount: 44)
        let bytes = okm.withUnsafeBytes { Data($0) }
        // nonce ровно 12 Б из вывода HKDF — инициализатор не бросит
        return (SymmetricKey(data: bytes.prefix(32)),
                try! ChaChaPoly.Nonce(data: bytes.suffix(12)))
    }
}

// MARK: - session2 (кодек 6)

/// Крипто и вращающийся тег — точно как кодек 4 (рэтчет Б не меняется);
/// отличия: байт кодека 6 в ad (домены 4↔6) и плейнтекст с префиксом
/// рев B (секунды + seq) вместо [unix-минуты 4].
extension RatchetEpoch {

    /// Замок протокола ревью 11.08 (п.4): счётчик 2 Б, ре-ключ положен
    /// при K=100 (`shouldRekey`), но правило без замка не работает (П9) —
    /// отправка на потолке невозможна КОДОМ, переполнение недостижимо.
    static let counterCeiling: UInt16 = 0xFFFF

    /// Собирает поток кодека 6: [6][тег 4][счётчик 2 LE][ct][AEAD 16].
    mutating func sealMessage2(innerCodec: UInt8, data: [UInt8],
                               sentAtSeconds: UInt32, seq: UInt32,
                               now: Date = Date()) throws -> [UInt8] {
        guard sendCounter < Self.counterCeiling else {
            throw RatchetError.sessionRefreshNeeded(
                "счётчик эпохи исчерпан — нужен ре-ключ")
        }
        let counter = sendCounter
        let tag = Ratchet.tag(tagKey: tagKey, initiator: iAmInitiator,
                              counter: counter)
        let mk = Ratchet.messageKey(ck: sendCK, at: now)
        sendCK = Ratchet.nextChain(sendCK)
        sendCounter += 1

        let plaintext = RevBPrefix(sentAtSeconds: sentAtSeconds, seq: seq,
                                   innerCodec: innerCodec,
                                   data: data).encode()
        let ad = [EnvelopeRevB.codecSession2] + tag
            + [UInt8(counter & 0xFF), UInt8(counter >> 8)]
        return ad + (try Ratchet.seal(plaintext: plaintext, mk: mk, ad: ad))
    }

    /// Открывает поток кодека 6. Окно счётчиков и отставшие ключи —
    /// ровно правило кодека 4 (openMessage); арифметика без wrap:
    /// потолок счётчика делает переполнение недостижимым.
    mutating func openMessage2(stream: [UInt8], now: Date = Date())
    throws -> (sentAtSeconds: UInt32, seq: UInt32,
               innerCodec: UInt8, data: [UInt8]) {
        guard stream.count > 1 + EnvelopeV2.tagLength + 2 + 16,
              stream[0] == EnvelopeRevB.codecSession2 else {
            throw EnvelopeError.malformed("это не session2-поток")
        }
        let tag = Array(stream[1...(EnvelopeV2.tagLength)])
        let counter = UInt16(stream[5]) | UInt16(stream[6]) << 8
        // Легитимный отправитель счётчик-потолок не шлёт (свой замок);
        // подделка с ним не должна доходить до арифметики counter+1.
        guard counter < Self.counterCeiling else {
            throw RatchetError.notForUs
        }
        let ct = Array(stream.dropFirst(7))
        let ad = Array(stream.prefix(7))

        // чистка протухших отставших ключей (TTL 14 дней)
        skipped = skipped.filter {
            now.timeIntervalSince($0.value.storedAt) < Ratchet.skippedTTL
        }

        let mk: Ratchet.MessageKey
        if let waiting = skipped[counter] {
            guard Ratchet.constantTimeEqual(
                Ratchet.tag(tagKey: tagKey, initiator: !iAmInitiator,
                            counter: counter), tag) else {
                throw RatchetError.notForUs
            }
            mk = waiting
            skipped[counter] = nil
        } else if counter >= recvNext,
                  Ratchet.constantTimeEqual(
                    Ratchet.tag(tagKey: tagKey, initiator: !iAmInitiator,
                                counter: counter), tag) {
            let gap = Int(counter) - Int(recvNext)
            guard gap < Ratchet.maxSkip else {
                throw RatchetError.sessionRefreshNeeded(
                    "дыра \(gap) глубже потолка \(Ratchet.maxSkip)")
            }
            guard skipped.count + gap <= Ratchet.maxSkip else {
                throw RatchetError.sessionRefreshNeeded(
                    "хранилище отставших ключей переполнено")
            }
            var ck = recvCK
            for c in recvNext..<counter {
                skipped[c] = Ratchet.messageKey(ck: ck, at: now)
                ck = Ratchet.nextChain(ck)
            }
            mk = Ratchet.messageKey(ck: ck, at: now)
            recvCK = Ratchet.nextChain(ck)
            recvNext = counter + 1
        } else if counter < recvNext {
            throw RatchetError.duplicate
        } else {
            throw RatchetError.notForUs
        }

        let plain: [UInt8]
        do {
            plain = try Ratchet.open(wire: ct, mk: mk, ad: ad)
        } catch {
            throw RatchetError.sessionRefreshNeeded(
                "ключ не подошёл — состояние сессий разошлось")
        }
        let prefix = try RevBPrefix.decode(plain)
        return (prefix.sentAtSeconds, prefix.seq,
                prefix.innerCodec, prefix.data)
    }
}
