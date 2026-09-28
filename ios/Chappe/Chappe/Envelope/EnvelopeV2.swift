import Foundation
import CryptoKit

// ============================================================================
// Envelope v2 — рамка ревизии (docs/RM_Envelope_v2_draft.md, 02.08).
//
// Одна ревизия, вторых не будет: рэтчет Б (кодек 4 session) + адресация
// релейного транспорта (dst 8 Б под флагом hasAddress). По радио флаг
// выключен — v2 не стоит там ни байта сверх v1-минус-метка.
//
// №5 закрыт: метка времени (unix-минуты) живёт ВНУТРИ шифртекста
// кодеков 3/4 — в открытом виде её в v2 нет. Кодеки 0–2 остаются
// раскладкой v1 (их v2-рамка не использует).
//
// v1 (Envelope.swift) НЕ трогается: старый приёмник на v2-пакете
// отказывает на заголовке («неизвестная версия формата») — явно,
// без падения и мусора; это его штатная защита и наш тест WP3.
// ============================================================================

nonisolated enum EnvelopeV2 {

    static let version: UInt8 = 2
    /// Кодек 4: сообщение эпохи рэтчета (ADR 007, вариант Б).
    static let codecSession: UInt8 = 4
    /// Новый флаг v2 (бит 4): за заголовком идёт адресный блок dst 8 Б.
    static let flagHasAddress: UInt8 = 1 << 4
    /// B3 (шов, подпись владельца 11.08): бит 5 = FRAG2 — нарезка u16
    /// для >255 кусков. Старый v2-приёмник на бите честно (мягко)
    /// роняет кадр; биты 0 и 5 взаимоисключающие.
    static let flagFrag2: UInt8 = 1 << 5

    static let tagLength = 4        // вращающийся тег эпохи
    static let dstLength = 8        // суточный псевдоним ящика

    /// Потолок СТАРОГО блока [index u8][total u8] в v2 — 255 по
    /// подписанному тексту шва («≤255 кусков обязаны ходить старой
    /// нарезкой»); прежние 16 — политика v0 §7, она остаётся только
    /// на v0/v1-пути TEXT (Envelope.maxFragments).
    static let maxFragmentsU8 = 255
    static let frag2MaxTotal = 0xFFFF
    /// Потолок контрольной длины сообщения (П3): 16 МиБ.
    static let frag2MsgLenCap = 16_777_216
    /// Кадр после нарезки ≤ 65535 Б — длина u16 в обёртке №7 (WirePadding).
    static let maxFrameBytes = 0xFFFF

    struct Frame: Equatable {
        var msgID: UInt16
        var wantAck: Bool
        var dst: [UInt8]?           // nil — радио (флага нет)
        var fragment: (index: Int, total: Int)?
        /// B3: блок FRAG2 [index u16][total u16][msg_len u32].
        var frag2: (index: Int, total: Int, msgLen: Int)?
        var stream: [UInt8]         // [кодек][…]; метки времени тут НЕТ

        static func == (a: Frame, b: Frame) -> Bool {
            a.msgID == b.msgID && a.wantAck == b.wantAck && a.dst == b.dst
                && a.fragment?.index == b.fragment?.index
                && a.fragment?.total == b.fragment?.total
                && a.frag2?.index == b.frag2?.index
                && a.frag2?.total == b.frag2?.total
                && a.frag2?.msgLen == b.frag2?.msgLen
                && a.stream == b.stream
        }
    }

    // MARK: Сборка

    /// Пакует готовый поток ([кодек][данные]) в v2-рамку TEXT.
    /// dst = nil — радио; иначе 8 Б суточного псевдонима (релей).
    static func encodePackets(msgID: UInt16, stream: [UInt8],
                              dst: [UInt8]? = nil,
                              wantAck: Bool = false,
                              maxPayload: Int = Envelope.maxPayload)
    throws -> [[UInt8]] {
        if let dst, dst.count != dstLength {
            throw EnvelopeError.badValue("dst обязан быть \(dstLength) Б")
        }
        var flags: UInt8 = wantAck ? Envelope.flagAckRequest : 0
        if dst != nil { flags |= flagHasAddress }
        let address = dst ?? []

        func header(_ extraFlags: UInt8 = 0) -> [UInt8] {
            [(version << 4) | Envelope.classText, flags | extraFlags]
                + Envelope.le16(msgID)
        }

        // адресный блок — в КАЖДОМ пакете (релей маршрутизирует пакеты,
        // не сообщения), сразу после заголовка, до блока фрагментации
        let perPacket = Envelope.headerSize + address.count
        guard maxPayload <= maxFrameBytes else {
            throw EnvelopeError.badValue(
                "v2: maxPayload \(maxPayload) выше потолка обёртки №7")
        }
        if perPacket + stream.count <= maxPayload {
            return [header() + address + stream]
        }

        func slice(_ chunkSize: Int) -> [[UInt8]] {
            var chunks: [[UInt8]] = []
            var i = 0
            while i < stream.count {
                chunks.append(Array(stream[i..<min(i + chunkSize,
                                                   stream.count)]))
                i += chunkSize
            }
            return chunks
        }

        // Гейт B3 (подпись 11.08): FRAG2 СТРОГО при >255 кусков старой
        // нарезки — мелочь ходит старым блоком u8, межверсионная
        // доставка обычных сообщений не страдает.
        let oldChunks = slice(maxPayload - perPacket - 2)
        if oldChunks.count <= maxFragmentsU8 {
            return oldChunks.enumerated().map { index, chunk in
                header(Envelope.flagFragmented) + address
                    + [UInt8(index), UInt8(oldChunks.count)] + chunk
            }
        }

        // FRAG2: блок [index u16][total u16][msg_len u32] в каждом пакете
        let chunks = slice(maxPayload - perPacket - 8)
        guard chunks.count <= frag2MaxTotal else {
            throw EnvelopeError.badValue(
                "FRAG2: \(chunks.count) кусков выше потолка \(frag2MaxTotal)")
        }
        guard stream.count <= frag2MsgLenCap else {
            throw EnvelopeError.badValue(
                "FRAG2: \(stream.count) Б выше потолка \(frag2MsgLenCap)")
        }
        let msgLen = UInt32(stream.count)
        return chunks.enumerated().map { index, chunk in
            header(flagFrag2) + address
                + Envelope.le16(UInt16(index))
                + Envelope.le16(UInt16(chunks.count))
                + EnvelopeRevB.le32(msgLen) + chunk
        }
    }

    // MARK: Разбор

    /// Разбирает v2-пакет TEXT. Бросает на любой другой версии/классе.
    static func decode(_ packet: [UInt8]) throws -> Frame {
        guard packet.count >= Envelope.headerSize else {
            throw EnvelopeError.tooShort("v2: пакет короче заголовка")
        }
        guard packet[0] >> 4 == version else {
            throw EnvelopeError.badValue("это не v2-пакет")
        }
        guard packet[0] & 0x0F == Envelope.classText else {
            throw EnvelopeError.badValue("v2: неизвестный класс \(packet[0] & 0x0F)")
        }
        let flags = packet[1]
        // рев B: v2 знает биты 0–5; 6–7 зарезервированы и обязаны быть
        // нулями (до B3 зарезервированным был и бит 5 — старый приёмник
        // мягко роняет FRAG2-кадр здесь, это штатная деградация WP3)
        guard flags & 0b1100_0000 == 0 else {
            throw EnvelopeError.badValue("v2: зарезервированные флаги не нулевые")
        }
        guard flags & Envelope.flagFragmented == 0
                || flags & flagFrag2 == 0 else {
            throw EnvelopeError.badValue("v2: биты 0 и 5 взаимоисключающие")
        }
        let msgID = UInt16(packet[2]) | UInt16(packet[3]) << 8
        var rest = Array(packet.dropFirst(Envelope.headerSize))

        var dst: [UInt8]?
        if flags & flagHasAddress != 0 {
            guard rest.count >= dstLength else {
                throw EnvelopeError.malformed("v2: адресный блок обрезан")
            }
            dst = Array(rest[0..<dstLength])
            rest = Array(rest.dropFirst(dstLength))
        }

        var fragment: (Int, Int)?
        var frag2: (Int, Int, Int)?
        if flags & Envelope.flagFragmented != 0 {
            guard rest.count > 2 else {
                throw EnvelopeError.malformed("v2: фрагмент без блока фрагментации")
            }
            let index = Int(rest[0]), total = Int(rest[1])
            // потолок u8-пути — 255 (рев B, подписанный текст шва)
            guard total >= 1, total <= maxFragmentsU8, index < total else {
                throw EnvelopeError.badValue("v2: недопустимая фрагментация")
            }
            fragment = (index, total)
            rest = Array(rest.dropFirst(2))
        } else if flags & flagFrag2 != 0 {
            guard rest.count > 8 else {
                throw EnvelopeError.malformed("FRAG2: блок обрезан")
            }
            let index = Int(rest[0]) | Int(rest[1]) << 8
            let total = Int(rest[2]) | Int(rest[3]) << 8
            let msgLen = Int(rest[4]) | Int(rest[5]) << 8
                | Int(rest[6]) << 16 | Int(rest[7]) << 24
            // приёмный гейт: ≤255 кусков обязаны ходить старой нарезкой
            guard total > maxFragmentsU8 else {
                throw EnvelopeError.badValue(
                    "FRAG2: total \(total) ≤ \(maxFragmentsU8) — обязана старая нарезка")
            }
            guard index < total else {
                throw EnvelopeError.badValue("FRAG2: index ≥ total")
            }
            guard msgLen <= frag2MsgLenCap else {
                throw EnvelopeError.badValue(
                    "FRAG2: msg_len выше потолка \(frag2MsgLenCap)")
            }
            frag2 = (index, total, msgLen)
            rest = Array(rest.dropFirst(8))
        }
        return Frame(msgID: msgID,
                     wantAck: flags & Envelope.flagAckRequest != 0,
                     dst: dst, fragment: fragment, frag2: frag2,
                     stream: rest)
    }
}

// MARK: - Суточный псевдоним ящика (dst)

/// Псевдоним ящика вращается по ЭПОХАМ пары (решение владельца 04.08).
///
/// dst = SHA-256(pubkey получателя ‖ ключ пары ‖ номер эпохи LE)[0..8];
/// граница эпохи сдвинута на shift(e) = HMAC(ключ пары,
/// "mailbox-shift" ‖ e) mod 86400 секунд от полуночи UTC.
///
/// Почему не полночь UTC (как было до 04.08): для Вьетнама и Бали она
/// приходится на 7-8 утра — человеческий день ложился в два псевдонима
/// и сшивался активным диалогом (найдено разбором приватности,
/// docs/relay_privacy.md).
/// Почему не ПОСТОЯННЫЙ сдвиг от ключа пары: постоянная фаза ротации
/// сама становится отпечатком пары — релей вычисляет её за пару недель
/// наблюдений и связывает псевдонимы между сутками, ломая ровно ту
/// несвязываемость, ради которой dst вращается.
/// Псевдослучайный сдвиг на каждую эпоху: оба конца считают одинаково,
/// для релея граница каждый раз в новом месте.
///
/// Ключ пары входит и в сам dst: разные отправители пишут одному
/// получателю в РАЗНЫЕ ящики — релей больше не видит всех
/// корреспондентов в одном.
nonisolated enum MailboxID {

    static let epochLength: TimeInterval = 86400
    /// Окно приёма по ВРЕМЕНИ, а не по числу эпох: длина эпохи
    /// плавает (сдвиг псевдослучаен), поэтому «−2…+1 эпохи» покрывали
    /// бы разный интервал. Назад — сколько релей хранит (48 ч),
    /// вперёд — запас на расхождение часов отправителя.
    static let windowBack: TimeInterval = 48 * 3600
    static let windowForward: TimeInterval = 24 * 3600

    /// Ключ пары: X25519(мой приватный, публичный собеседника) → HKDF.
    /// Считается одинаково с обоих концов, релею неизвестен.
    static func pairKey(myPrivate: Curve25519.KeyAgreement.PrivateKey,
                        peerPublic: Curve25519.KeyAgreement.PublicKey)
    throws -> Data {
        let shared = try myPrivate.sharedSecretFromKeyAgreement(
            with: peerPublic)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("RM-Mailbox-v1".utf8),
            sharedInfo: Data(), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Сдвиг границы эпохи, секунды от полуночи UTC.
    static func shift(pairKey: Data, epoch: Int) -> Int {
        var input = Data("mailbox-shift".utf8)
        input.append(contentsOf: Self.le32(epoch))
        let mac = HMAC<SHA256>.authenticationCode(
            for: input, using: SymmetricKey(data: pairKey))
        let bytes = Array(mac.prefix(4))
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Int(value % 86400)
    }

    /// Момент начала эпохи (unix-секунды). Строго возрастает по epoch:
    /// сдвиг < длины эпохи, поэтому границы не перехлёстываются.
    static func boundary(pairKey: Data, epoch: Int) -> TimeInterval {
        Double(epoch) * epochLength
            + Double(shift(pairKey: pairKey, epoch: epoch))
    }

    /// Эпоха, которой принадлежит момент.
    static func epoch(pairKey: Data, at date: Date) -> Int {
        let t = date.timeIntervalSince1970
        let base = Int(floor(t / epochLength))
        // граница base+1 всегда позже t (t < (base+1)*86400 ≤ границы),
        // значит кандидатов ровно два: base и base-1
        return boundary(pairKey: pairKey, epoch: base) <= t ? base : base - 1
    }

    static func dst(recipientPub: Data, pairKey: Data, epoch: Int) -> [UInt8] {
        var input = Data(recipientPub)
        input.append(pairKey)
        input.append(contentsOf: Self.le32(epoch))
        return Array(Data(SHA256.hash(data: input))
            .prefix(EnvelopeV2.dstLength))
    }

    /// Отправитель: псевдоним по СВОИМ часам на текущую эпоху пары.
    static func dstForSending(recipientPub: Data, pairKey: Data,
                              now: Date = Date()) -> [UInt8] {
        dst(recipientPub: recipientPub, pairKey: pairKey,
            epoch: epoch(pairKey: pairKey, at: now))
    }

    /// Эпохи, пересекающие приёмное окно. Перечисляются подряд от
    /// эпохи «сейчас минус 48 ч» до эпохи «сейчас плюс 24 ч» — так
    /// короткая эпоха (сдвиг соседей разошёлся) не проваливается
    /// между выборками. Потолок — страховка от бесконечного цикла.
    static func acceptedEpochs(pairKey: Data, now: Date = Date()) -> [Int] {
        let first = epoch(pairKey: pairKey,
                          at: now.addingTimeInterval(-windowBack))
        let last = epoch(pairKey: pairKey,
                         at: now.addingTimeInterval(windowForward))
        guard last >= first else { return [first] }
        return Array(first...min(last, first + 8))
    }

    static func acceptedDsts(myPub: Data, pairKey: Data,
                             now: Date = Date()) -> [[UInt8]] {
        acceptedEpochs(pairKey: pairKey, now: now).map {
            dst(recipientPub: myPub, pairKey: pairKey, epoch: $0)
        }
    }

    static func isMine(_ candidate: [UInt8], myPub: Data, pairKey: Data,
                       now: Date = Date()) -> Bool {
        acceptedDsts(myPub: myPub, pairKey: pairKey, now: now)
            .contains(candidate)
    }

    private static func le32(_ value: Int) -> [UInt8] {
        let v = UInt32(clamping: value)
        return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
}
