import Foundation

// ============================================================================
// Классы сообщений Envelope v0 (§3–§7 спеки) — порт sim/envelope.py.
//
// Каждый encode() обязан давать те же байты, что Python-версия:
// проверяется общими тест-векторами tests/envelope_test_vectors.json.
// ============================================================================

// MARK: - SOS (0x1): широковещательный, не шифруется, не фрагментируется

nonisolated struct SOSMessage: Equatable, Sendable {
    var msgID: UInt16
    var severity: Int                // 0…3
    var peopleCount: Int             // 0…62, 63 = «больше / неизвестно»
    var injury: Int                  // 0…15
    var hopsLeft: Int = 3
    var lat: Double?                 // грубая широта (nil = нет фикса GPS)
    var lon: Double?
    var needs: Set<Int> = []         // номера бит 0…15
    var textTail: String?
    var tailCodec: UInt8 = Envelope.codecStore

    /// Собирает SOS в байты. Результат всегда ≤ maxPayload (принцип П5:
    /// у SOS режется хвост, но сам сигнал не фрагментируется никогда).
    func encode(maxPayload: Int = Envelope.maxPayload) throws -> [UInt8] {
        try checkRange("severity", severity, 0, 3)
        try checkRange("people_count", peopleCount, 0, 63)
        try checkRange("injury", injury, 0, 15)
        try checkRange("hops_left", hopsLeft, 0, 15)
        guard (lat == nil) == (lon == nil) else {
            throw EnvelopeError.badValue("широта и долгота задаются только вместе")
        }

        var flags: UInt8 = 0

        // байт 4: severity в старших 2 битах, people_count в младших 6
        // байт 5: injury в старших 4 битах, hops_left в младших 4
        var body: [UInt8] = [
            UInt8((severity << 6) | peopleCount),
            UInt8((injury << 4) | hopsLeft),
        ]

        // байты 6-9: грубые координаты; если фикса нет — единицы (0xFF)
        if let lat, let lon {
            body += try Envelope.encodeCoarseCoords(lat: lat, lon: lon)
            flags |= Envelope.flagHasCoords
        } else {
            body += Envelope.le16(Envelope.noCoarse) + Envelope.le16(Envelope.noCoarse)
        }

        // байты 10-11: маска потребностей
        body += try Envelope.encodeNeeds(needs)

        // Хвост — только если ВЕСЬ пакет влезает в один LoRa-пакет
        var tail: [UInt8] = []
        if let textTail, !textTail.isEmpty {
            let data = try TextCodec.compress(textTail, codec: tailCodec)
            let fits = Envelope.headerSize + body.count + 2 + data.count <= maxPayload
            if fits && data.count <= 255 {
                tail = [tailCodec, UInt8(data.count)] + data
                flags |= Envelope.flagHasTail
            }
        }

        return Envelope.encodeHeader(msgClass: Envelope.classSOS,
                                     flags: flags, msgID: msgID) + body + tail
    }

    static func decodeBody(flags: UInt8, msgID: UInt16, packet: [UInt8]) throws -> SOSMessage {
        guard packet.count >= 12 else {
            throw EnvelopeError.tooShort("SOS-пакет слишком короткий: \(packet.count) байт, нужно минимум 12")
        }
        let severity = Int(packet[4] >> 6)
        let peopleCount = Int(packet[4] & 0x3F)
        let injury = Int(packet[5] >> 4)
        let hopsLeft = Int(packet[5] & 0x0F)

        // Присутствие координат определяет флаг 3, а не содержимое байтов
        var lat: Double?, lon: Double?
        if flags & Envelope.flagHasCoords != 0 {
            (lat, lon) = Envelope.decodeCoarseCoords(packet[6..<10])
        }

        let needs = Envelope.decodeNeeds(packet[10..<12])

        var textTail: String?
        var tailCodec = Envelope.codecStore
        if flags & Envelope.flagHasTail != 0 {
            guard packet.count >= 14 else {
                throw EnvelopeError.malformed("флаг хвоста установлен, а хвоста нет")
            }
            tailCodec = packet[12]
            let length = Int(packet[13])
            guard packet.count >= 14 + length else {
                throw EnvelopeError.malformed("хвост оборван: заявлено \(length) байт, есть \(packet.count - 14)")
            }
            textTail = try TextCodec.decompress(Array(packet[14..<14 + length]), codec: tailCodec)
        }

        return SOSMessage(msgID: msgID, severity: severity, peopleCount: peopleCount,
                          injury: injury, hopsLeft: hopsLeft, lat: lat, lon: lon,
                          needs: needs, textTail: textTail, tailCodec: tailCodec)
    }
}

// MARK: - BEACON (0x2): маячок статуса после SOS (§5б)

nonisolated struct BeaconMessage: Equatable, Sendable {
    var msgID: UInt16
    var sosMsgID: UInt16             // msg_id исходного SOS
    var status: Int                  // 0…3; выставляет только сам пострадавший
    var responders: Int              // 0…62, 63 = «много»
    var lat: Double?                 // грубые координаты, если переместился
    var lon: Double?

    func encode() throws -> [UInt8] {
        try checkRange("status", status, 0, 3)
        try checkRange("responders", responders, 0, 63)
        guard (lat == nil) == (lon == nil) else {
            throw EnvelopeError.badValue("широта и долгота задаются только вместе")
        }
        var flags: UInt8 = 0
        var body = Envelope.le16(sosMsgID)
        body.append(UInt8((status << 6) | responders))
        if let lat, let lon {
            body += try Envelope.encodeCoarseCoords(lat: lat, lon: lon)
            flags |= Envelope.flagHasCoords
        }
        return Envelope.encodeHeader(msgClass: Envelope.classBeacon,
                                     flags: flags, msgID: msgID) + body
    }

    static func decodeBody(flags: UInt8, msgID: UInt16, packet: [UInt8]) throws -> BeaconMessage {
        guard packet.count >= 7 else {
            throw EnvelopeError.tooShort("BEACON-пакет слишком короткий: \(packet.count) байт, нужно минимум 7")
        }
        let sosMsgID = UInt16(packet[4]) | UInt16(packet[5]) << 8
        let status = Int(packet[6] >> 6)
        let responders = Int(packet[6] & 0x3F)
        var lat: Double?, lon: Double?
        if flags & Envelope.flagHasCoords != 0 {
            guard packet.count >= 11 else {
                throw EnvelopeError.malformed("флаг координат установлен, а координат нет")
            }
            (lat, lon) = Envelope.decodeCoarseCoords(packet[7..<11])
        }
        return BeaconMessage(msgID: msgID, sosMsgID: sosMsgID, status: status,
                             responders: responders, lat: lat, lon: lon)
    }
}

// MARK: - ACK (0x4): подтверждение доставки (§5а)

nonisolated struct AckMessage: Equatable, Sendable {
    var msgID: UInt16       // свой, новый msg_id этого ACK
    var ackMsgID: UInt16    // msg_id сообщения, которое подтверждаем

    func encode() -> [UInt8] {
        Envelope.encodeHeader(msgClass: Envelope.classAck, flags: 0, msgID: msgID)
            + Envelope.le16(ackMsgID)
    }

    static func decodeBody(flags: UInt8, msgID: UInt16, packet: [UInt8]) throws -> AckMessage {
        guard packet.count >= 6 else {
            throw EnvelopeError.tooShort("ACK-пакет слишком короткий: \(packet.count) байт, нужно минимум 6")
        }
        return AckMessage(msgID: msgID, ackMsgID: UInt16(packet[4]) | UInt16(packet[5]) << 8)
    }
}

// MARK: - LOCATION (0x5): точные координаты в личном чате

nonisolated struct LocationMessage: Equatable, Sendable {
    var msgID: UInt16
    var lat: Double?        // nil = нет фикса GPS
    var lon: Double?
    var wantAck: Bool = false

    func encode() throws -> [UInt8] {
        guard (lat == nil) == (lon == nil) else {
            throw EnvelopeError.badValue("широта и долгота задаются только вместе")
        }
        var flags: UInt8 = wantAck ? Envelope.flagAckRequest : 0
        let body: [UInt8]
        if let lat, let lon {
            body = try Envelope.encodeFineCoords(lat: lat, lon: lon)
            flags |= Envelope.flagHasCoords
        } else {
            body = Envelope.le24(Envelope.noFine) + Envelope.le24(Envelope.noFine)
        }
        return Envelope.encodeHeader(msgClass: Envelope.classLocation,
                                     flags: flags, msgID: msgID) + body
    }

    static func decodeBody(flags: UInt8, msgID: UInt16, packet: [UInt8]) throws -> LocationMessage {
        guard packet.count >= 10 else {
            throw EnvelopeError.tooShort("LOCATION-пакет слишком короткий: \(packet.count) байт, нужно минимум 10")
        }
        var lat: Double?, lon: Double?
        if flags & Envelope.flagHasCoords != 0 {
            (lat, lon) = Envelope.decodeFineCoords(packet[4..<10])
        }
        return LocationMessage(msgID: msgID, lat: lat, lon: lon,
                               wantAck: flags & Envelope.flagAckRequest != 0)
    }
}

// MARK: - TEXT (0x3): личное сообщение, единственный фрагментируемый класс

nonisolated struct EnvelopeTextMessage: Equatable, Sendable {
    var msgID: UInt16
    var text: String
    var codec: UInt8 = Envelope.codecStore
    var wantAck: Bool = false
    /// unix-минуты отправки (v1; 0 = метка неизвестна).
    var sentAtMinutes: UInt32 = 0
}

nonisolated struct TextFragmentMessage: Equatable, Sendable {
    /// Версия конверта пакета-носителя (v1: собранный поток начинается
    /// с 4 байт метки времени).
    var packetVersion: UInt8 = 0
    var msgID: UInt16
    var index: Int      // номер фрагмента, от 0
    var total: Int      // всего фрагментов
    var chunk: [UInt8]  // кусок полезной нагрузки
    var wantAck: Bool = false
}

nonisolated enum TextEncoder {

    /// Собирает текстовое сообщение в один или несколько пакетов.
    /// Длину считает код, не модель (принцип П4).
    /// Полезная нагрузка: [кодек: 1 байт][сжатые байты текста].
    static func encode(msgID: UInt16, text: String,
                       codec: UInt8 = Envelope.codecStore,
                       wantAck: Bool = false,
                       maxPayload: Int = Envelope.maxPayload,
                       sentAtMinutes: UInt32? = nil) throws -> [[UInt8]] {
        try encodePackets(msgID: msgID,
                          payload: [codec] + (try TextCodec.compress(text,
                                                                     codec: codec)),
                          wantAck: wantAck, maxPayload: maxPayload,
                          sentAtMinutes: sentAtMinutes)
    }

    /// Пакует ГОТОВЫЙ payload ([кодек][данные], в т.ч. sealed box) в
    /// рамку TEXT — фрагментация та же (веха, фаза 3).
    static func encodePackets(msgID: UInt16, payload rawPayload: [UInt8],
                              wantAck: Bool = false,
                              maxPayload: Int = Envelope.maxPayload,
                              sentAtMinutes: UInt32? = nil)
    throws -> [[UInt8]] {
        let baseFlags: UInt8 = wantAck ? Envelope.flagAckRequest : 0
        // v1 (Ф5): 4 байта unix-минут отправки — префикс потока нагрузки
        // (0 = неизвестно); фрагментация режет поток как раньше
        let ts = sentAtMinutes
            ?? UInt32(Date().timeIntervalSince1970 / 60)
        let payload = [UInt8(ts & 0xFF), UInt8((ts >> 8) & 0xFF),
                       UInt8((ts >> 16) & 0xFF), UInt8((ts >> 24) & 0xFF)]
                      + rawPayload

        // Помещается целиком — один пакет, без блока фрагментации
        if Envelope.headerSize + payload.count <= maxPayload {
            return [Envelope.encodeHeader(msgClass: Envelope.classText,
                                          flags: baseFlags, msgID: msgID) + payload]
        }

        // Не помещается — режем. После заголовка 2 байта: [номер][всего] (§7)
        let chunkSize = maxPayload - Envelope.headerSize - 2
        var chunks: [[UInt8]] = []
        var i = 0
        while i < payload.count {
            chunks.append(Array(payload[i..<min(i + chunkSize, payload.count)]))
            i += chunkSize
        }
        guard chunks.count <= Envelope.maxFragments else {
            throw EnvelopeError.badValue(
                "сообщение требует \(chunks.count) фрагментов, а максимум \(Envelope.maxFragments); "
                + "текст надо сократить (это делает код приложения, не модель)")
        }

        let flags = baseFlags | Envelope.flagFragmented
        return chunks.enumerated().map { index, chunk in
            Envelope.encodeHeader(msgClass: Envelope.classText, flags: flags, msgID: msgID)
                + [UInt8(index), UInt8(chunks.count)] + chunk
        }
    }

    /// Разбирает собранную нагрузку TEXT: [кодек][сжатые байты] → (кодек, текст).
    static func decodePayload(_ payload: [UInt8]) throws -> (codec: UInt8, text: String) {
        guard !payload.isEmpty else {
            throw EnvelopeError.malformed("пустая полезная нагрузка TEXT")
        }
        let codec = payload[0]
        return (codec, try TextCodec.decompress(Array(payload.dropFirst()), codec: codec))
    }
}

// MARK: - Общий вход: разобрать любой пакет

/// Результат разбора пакета — одно из сообщений Envelope.
nonisolated enum EnvelopeMessage: Equatable, Sendable {
    case sos(SOSMessage)
    case beacon(BeaconMessage)
    case ack(AckMessage)
    case location(LocationMessage)
    case text(EnvelopeTextMessage)
    case textFragment(TextFragmentMessage)
}

nonisolated enum EnvelopeDecoder {

    static func decode(_ packet: [UInt8]) throws -> EnvelopeMessage {
        let (msgClass, flags, msgID) = try Envelope.decodeHeader(packet)

        switch msgClass {
        case Envelope.classSOS:
            return .sos(try SOSMessage.decodeBody(flags: flags, msgID: msgID, packet: packet))
        case Envelope.classBeacon:
            return .beacon(try BeaconMessage.decodeBody(flags: flags, msgID: msgID, packet: packet))
        case Envelope.classAck:
            return .ack(try AckMessage.decodeBody(flags: flags, msgID: msgID, packet: packet))
        case Envelope.classLocation:
            return .location(try LocationMessage.decodeBody(flags: flags, msgID: msgID, packet: packet))
        case Envelope.classText:
            let wantAck = flags & Envelope.flagAckRequest != 0
            if flags & Envelope.flagFragmented != 0 {
                guard packet.count >= Envelope.headerSize + 2 else {
                    throw EnvelopeError.malformed("фрагмент без блока фрагментации")
                }
                let index = Int(packet[4]), total = Int(packet[5])
                guard total >= 1, total <= Envelope.maxFragments else {
                    throw EnvelopeError.badValue("недопустимое число фрагментов: \(total)")
                }
                guard index < total else {
                    throw EnvelopeError.badValue("номер фрагмента \(index) ≥ общего числа \(total)")
                }
                return .textFragment(TextFragmentMessage(
                    packetVersion: packet[0] >> 4,
                    msgID: msgID, index: index, total: total,
                    chunk: Array(packet.dropFirst(6)), wantAck: wantAck))
            }
            var stream = Array(packet.dropFirst(4))
            var sentAtMinutes: UInt32 = 0
            if packet[0] >> 4 >= 1 {          // v1: метка в потоке
                guard stream.count >= 4 else {
                    throw EnvelopeError.malformed("v1 TEXT без метки времени")
                }
                sentAtMinutes = UInt32(stream[0]) | UInt32(stream[1]) << 8
                    | UInt32(stream[2]) << 16 | UInt32(stream[3]) << 24
                stream = Array(stream.dropFirst(4))
            }
            let (codec, text) = try TextEncoder.decodePayload(stream)
            return .text(EnvelopeTextMessage(msgID: msgID, text: text,
                                             codec: codec, wantAck: wantAck,
                                             sentAtMinutes: sentAtMinutes))
        default:
            throw EnvelopeError.badValue("неизвестный класс сообщения: \(msgClass)")
        }
    }
}

// MARK: - Сборка фрагментов (§7)

/// Собирает длинные TEXT-сообщения из фрагментов. Правила §7: сборка по
/// msg_id, любой порядок, дубликаты отбрасываются, неполное сообщение
/// живёт 10 минут. Время передаётся снаружи — поведение воспроизводимо
/// в тестах без настоящих часов.
nonisolated final class Reassembler {

    private struct Pending {
        let total: Int
        var parts: [Int: [UInt8]]
        let born: Double
    }

    private let timeout: Double
    private var pending: [UInt16: Pending] = [:]

    init(timeout: Double = Envelope.reassemblyTimeout) {
        self.timeout = timeout
    }

    /// Принимает фрагмент. Возвращает собранный текст, если этот фрагмент
    /// был последним недостающим, иначе nil.
    func add(_ fragment: TextFragmentMessage, now: Double = 0.0) throws -> String? {
        purge(now: now)

        if var rec = pending[fragment.msgID] {
            guard fragment.total == rec.total else {
                throw EnvelopeError.malformed(String(
                    format: "фрагменты msg_id=0x%04X сообщают разное общее число частей: %d и %d",
                    fragment.msgID, rec.total, fragment.total))
            }
            // Дубликат (уже известный номер) просто игнорируется
            if rec.parts[fragment.index] == nil {
                rec.parts[fragment.index] = fragment.chunk
            }
            pending[fragment.msgID] = rec
        } else {
            pending[fragment.msgID] = Pending(total: fragment.total,
                                              parts: [fragment.index: fragment.chunk],
                                              born: now)
        }

        guard let rec = pending[fragment.msgID], rec.parts.count == rec.total else {
            return nil  // ещё не всё пришло
        }

        // Все фрагменты на месте: склеиваем по номерам и разбираем
        var payload: [UInt8] = []
        for i in 0..<rec.total {
            payload += rec.parts[i] ?? []
        }
        pending[fragment.msgID] = nil
        // v1: собранный поток начинается с 4 байт метки отправки
        if fragment.packetVersion >= 1 {
            guard payload.count >= 4 else {
                throw EnvelopeError.malformed("v1 поток без метки времени")
            }
            lastSentAtMinutes = UInt32(payload[0]) | UInt32(payload[1]) << 8
                | UInt32(payload[2]) << 16 | UInt32(payload[3]) << 24
            payload = Array(payload.dropFirst(4))
        }
        return try TextEncoder.decodePayload(payload).text
    }

    /// Метка отправки последнего собранного сообщения (v1; 0 = нет).
    private(set) var lastSentAtMinutes: UInt32 = 0

    var pendingCount: Int { pending.count }

    private func purge(now: Double) {
        pending = pending.filter { now - $0.value.born <= timeout }
    }
}

// MARK: - Проверка диапазона (принцип П3: у каждого поля есть потолок)

private nonisolated func checkRange(_ name: String, _ value: Int, _ lo: Int, _ hi: Int) throws {
    guard (lo...hi).contains(value) else {
        throw EnvelopeError.badValue("поле «\(name)» = \(value), а допустимо от \(lo) до \(hi)")
    }
}
