import Foundation

// ============================================================================
// Envelope v0 — константы формата, координаты, маска needs, заголовок.
//
// Порт sim/envelope.py по спеке docs/RM_Envelope_v0.md. Обе реализации
// обязаны проходить tests/envelope_test_vectors.json ПОБАЙТОВО — любое
// расхождение с Python-версией это баг.
//
// Главный принцип — КАНОНИЧНОСТЬ (П6): одни данные → всегда одни байты.
// Порядок полей зашит в коде, многобайтовые числа — little-endian,
// округление координат — строго floor(x + 0.5) (§5 спеки).
// ============================================================================

nonisolated enum Envelope {

    /// v1 (29.07.2026, Ф5): TEXT несёт 4 байта unix-минут отправки
    /// префиксом потока нагрузки — относительное время в
    /// store-and-forward рендерится ОТ метки. Санкционированное
    /// изменение конверта; приёмник принимает версии 0-1.
    static let version: UInt8 = 1
    static let minVersion: UInt8 = 0

    // Классы сообщений (§3)
    static let classSOS: UInt8 = 0x1
    static let classBeacon: UInt8 = 0x2
    static let classText: UInt8 = 0x3
    static let classAck: UInt8 = 0x4
    static let classLocation: UInt8 = 0x5
    /// Отметка о прочтении (02.08, просьба владельца: второе время
    /// зеленеет). Аддитивный класс: старый приёмник отвергает его
    /// честной ошибкой «неизвестный класс», не падая.
    static let classRead: UInt8 = 0x6

    // Флаги в байте 1 заголовка (§4). Бит 0 — младший.
    static let flagFragmented: UInt8 = 1 << 0
    static let flagAckRequest: UInt8 = 1 << 1
    static let flagHasTail: UInt8 = 1 << 2
    static let flagHasCoords: UInt8 = 1 << 3
    // биты 4–7 зарезервированы и обязаны быть нулями

    static let headerSize = 4
    static let maxPayload = 200      // лимит LoRa-пакета (уточняется на железе)
    static let maxFragments = 16
    static let reassemblyTimeout = 600.0   // секунд (10 минут, §7)

    // «Координат нет»: поля-единицы (§5)
    static let noCoarse: UInt16 = 0xFFFF
    static let noFine: UInt32 = 0xFFFFFF

    static let peopleMany = 63       // people_count: «больше 62 / неизвестно»
    static let respondersMany = 63   // BEACON: «много откликнувшихся»

    // Кодеки сжатия текста (§6)
    static let codecStore: UInt8 = 0
    static let codecZlib: UInt8 = 1
    static let codecSemantic: UInt8 = 2   // коды словаря R+M (RMCodec)

    // MARK: Округление и координаты

    /// Каноническое округление: floor(x + 0.5), половина всегда вверх.
    /// Swift `rounded()` округляет от нуля, Python round() — к чётному;
    /// чтобы кодеки сходились побайтово, правило зафиксировано в спеке (§5).
    static func roundHalfUp(_ x: Double) -> Int {
        Int((x + 0.5).rounded(.down))
    }

    static func checkCoords(lat: Double, lon: Double) throws {
        guard (-90.0...90.0).contains(lat) else {
            throw EnvelopeError.badValue("широта \(lat) вне диапазона -90…90")
        }
        guard (-180.0...180.0).contains(lon) else {
            throw EnvelopeError.badValue("долгота \(lon) вне диапазона -180…180")
        }
    }

    /// Грубые координаты → 4 байта (2+2, LE). Точность ~300×600 м — нарочно.
    static func encodeCoarseCoords(lat: Double, lon: Double) throws -> [UInt8] {
        try checkCoords(lat: lat, lon: lon)
        let latCode = roundHalfUp((lat + 90.0) / 180.0 * 65535)
        let lonCode = roundHalfUp((lon + 180.0) / 360.0 * 65535)
        return le16(UInt16(latCode)) + le16(UInt16(lonCode))
    }

    static func decodeCoarseCoords(_ data: ArraySlice<UInt8>) -> (lat: Double, lon: Double) {
        let b = Array(data)
        let latCode = Double(UInt16(b[0]) | UInt16(b[1]) << 8)
        let lonCode = Double(UInt16(b[2]) | UInt16(b[3]) << 8)
        return (latCode / 65535 * 180.0 - 90.0, lonCode / 65535 * 360.0 - 180.0)
    }

    /// Точные координаты → 6 байт (3+3, LE). Только LOCATION, только личный
    /// чат, только после явного подтверждения пользователем.
    static func encodeFineCoords(lat: Double, lon: Double) throws -> [UInt8] {
        try checkCoords(lat: lat, lon: lon)
        let latCode = roundHalfUp((lat + 90.0) / 180.0 * 16777215)
        let lonCode = roundHalfUp((lon + 180.0) / 360.0 * 16777215)
        return le24(UInt32(latCode)) + le24(UInt32(lonCode))
    }

    static func decodeFineCoords(_ data: ArraySlice<UInt8>) -> (lat: Double, lon: Double) {
        let b = Array(data)
        let latCode = Double(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16)
        let lonCode = Double(UInt32(b[3]) | UInt32(b[4]) << 8 | UInt32(b[5]) << 16)
        return (latCode / 16777215 * 180.0 - 90.0, lonCode / 16777215 * 360.0 - 180.0)
    }

    // MARK: Маска потребностей (§6)

    /// Набор номеров бит (0…15) → 2 байта LE. Порядок добавления в набор
    /// на байты не влияет — каноничность.
    static func encodeNeeds(_ needs: Set<Int>) throws -> [UInt8] {
        var mask: UInt16 = 0
        for bit in needs {
            guard (0...15).contains(bit) else {
                throw EnvelopeError.badValue("needs: номер бита \(bit) вне 0…15")
            }
            mask |= 1 << UInt16(bit)
        }
        return le16(mask)
    }

    static func decodeNeeds(_ data: ArraySlice<UInt8>) -> Set<Int> {
        let b = Array(data)
        let mask = UInt16(b[0]) | UInt16(b[1]) << 8
        return Set((0..<16).filter { mask & (1 << UInt16($0)) != 0 })
    }

    // MARK: Общий заголовок (§4)

    static func encodeHeader(msgClass: UInt8, flags: UInt8, msgID: UInt16) -> [UInt8] {
        [(version << 4) | msgClass, flags] + le16(msgID)
    }

    /// Разбирает заголовок. Возвращает (класс, флаги, msgID).
    static func decodeHeader(_ packet: [UInt8]) throws -> (msgClass: UInt8, flags: UInt8, msgID: UInt16) {
        guard packet.count >= headerSize else {
            throw EnvelopeError.tooShort("пакет короче заголовка: \(packet.count) байт, нужно минимум \(headerSize)")
        }
        let ver = packet[0] >> 4
        guard ver >= minVersion, ver <= version else {
            throw EnvelopeError.badValue("неизвестная версия формата: \(ver) (поддерживается \(minVersion)-\(version))")
        }
        let flags = packet[1]
        guard flags & 0xF0 == 0 else {
            throw EnvelopeError.badValue("зарезервированные флаги (биты 4-7) должны быть нулевыми")
        }
        return (packet[0] & 0x0F, flags, UInt16(packet[2]) | UInt16(packet[3]) << 8)
    }

    // MARK: Байтовые помощники (little-endian)

    static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    static func le24(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)]
    }

    /// Случайный 16-битный идентификатор сообщения (§4).
    static func newMsgID() -> UInt16 {
        UInt16.random(in: 0...0xFFFF)
    }
}

/// Ошибки кодека. По-русски: их читает владелец проекта в логах и алертах.
nonisolated enum EnvelopeError: Error, LocalizedError {
    case badValue(String)
    case tooShort(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .badValue(let m), .tooShort(let m), .malformed(let m): m
        }
    }
}
