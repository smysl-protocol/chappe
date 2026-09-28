import Foundation
import Compression

// ============================================================================
// Сжатие текстового хвоста и TEXT-нагрузки (§6 спеки).
//
// Кодек сменный, его номер передаётся в пакете:
//   0 — без сжатия (UTF-8 как есть),
//   1 — zlib/deflate.
//
// Про совместимость zlib: libcompression Apple даёт «сырой» deflate без
// zlib-обёртки, а Python zlib.compress — deflate С обёрткой (2 байта
// заголовка + adler32 в конце). Чтобы стороны читали друг друга, здесь
// обёртка добавляется/снимается вручную. ВАЖНО: сжатые байты Python и
// Swift МОГУТ отличаться (разные реализации deflate) — это допустимо,
// т.к. любой корректный deflate разворачивается любой стороной.
// Каноничность подписи гарантируется только внутри одной платформы;
// тест-векторы используют кодек 0 (без сжатия).
// ============================================================================

nonisolated enum TextCodec {

    /// Гейт размера текстового пути: единая точка выбора кодека.
    /// До 05.08 текст всегда жёстко жался zlib — «ок» (2 Б) раздувался
    /// до ~10 Б на каждом подтверждении, а реплики ≤4 слов — треть
    /// живого трафика (аудит size_gate_audit_2026-08-05.md, №3–№6).
    /// Кандидаты — store и zlib (оба давно в формате, приёмник читает
    /// оба), побеждает меньший; при равенстве — store (дешевле CPU).
    static func best(_ text: String) -> (codec: UInt8, data: [UInt8]) {
        let raw = Array(text.utf8)
        guard let zl = try? zlibCompress(raw), zl.count < raw.count else {
            return (Envelope.codecStore, raw)
        }
        return (Envelope.codecZlib, zl)
    }

    /// Текст → байты по выбранному кодеку.
    static func compress(_ text: String, codec: UInt8) throws -> [UInt8] {
        let raw = Array(text.utf8)
        switch codec {
        case Envelope.codecStore:
            return raw
        case Envelope.codecZlib:
            return try zlibCompress(raw)
        default:
            throw EnvelopeError.badValue("неизвестный кодек сжатия: \(codec)")
        }
    }

    /// Байты → текст по выбранному кодеку.
    static func decompress(_ data: [UInt8], codec: UInt8) throws -> String {
        let raw: [UInt8]
        switch codec {
        case Envelope.codecStore:
            raw = data
        case Envelope.codecZlib:
            raw = try zlibDecompress(data)
        case Envelope.codecSemantic:
            // Семантические коды: разворот словарём на языке получателя.
            // (Кодирование этим кодеком идёт НЕ отсюда — из SemanticEncoder:
            // на входе юниты, а не текст.)
            guard let rm = RMCodec.shared else {
                throw EnvelopeError.badValue("семантический пакет, а словаря нет")
            }
            // Первый байт — отпечаток таблицы Хаффмана отправителя.
            // Не совпал — декодировать НЕЛЬЗЯ (будет мусор): честная
            // текстовая заглушка, блоб сохранён и развернётся после
            // обновления словаря (version skew, п.5).
            guard let blob = rm.unwrapWire(data) else {
                return "⚠︎ Сообщение в другой версии словаря — "
                     + "обнови приложение, текст развернётся"
            }
            // Язык — Dev-тумблер «Разворот: RU / EN» (взгляд англичанина)
            return rm.render(try rm.decode(blob), lang: RMCodec.unfoldLanguage)
        default:
            throw EnvelopeError.badValue("неизвестный кодек сжатия: \(codec)")
        }
        guard let text = String(bytes: raw, encoding: .utf8) else {
            throw EnvelopeError.malformed("текст не разбирается как UTF-8")
        }
        return text
    }

    // MARK: zlib-обёртка вокруг libcompression

    private static func zlibCompress(_ raw: [UInt8]) throws -> [UInt8] {
        guard !raw.isEmpty else {
            // Пустой вход: минимальный корректный zlib-поток
            return [0x78, 0xDA, 0x03, 0x00] + adler32BE([])
        }
        let dstCapacity = raw.count + 256
        var dst = [UInt8](repeating: 0, count: dstCapacity)
        let written = raw.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, dstCapacity,
                                          src.baseAddress!, raw.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else {
            throw EnvelopeError.malformed("zlib: сжатие не удалось")
        }
        // 0x78 0xDA — стандартный заголовок zlib (окно 32К, максимальное сжатие)
        return [0x78, 0xDA] + dst.prefix(written) + adler32BE(raw)
    }

    private static func zlibDecompress(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count > 6 else {
            throw EnvelopeError.malformed("zlib: поток слишком короткий")
        }
        // Снимаем 2 байта zlib-заголовка; хвостовой adler32 декодеру не мешает
        let deflate = Array(data.dropFirst(2))
        var capacity = max(1024, data.count * 8)
        for _ in 0..<8 {
            var dst = [UInt8](repeating: 0, count: capacity)
            let written = deflate.withUnsafeBufferPointer { src in
                dst.withUnsafeMutableBufferPointer { d in
                    compression_decode_buffer(d.baseAddress!, capacity,
                                              src.baseAddress!, deflate.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 {
                throw EnvelopeError.malformed("zlib: распаковка не удалась")
            }
            if written < capacity {
                return Array(dst.prefix(written))
            }
            capacity *= 4   // буфер оказался мал — растим и повторяем
        }
        throw EnvelopeError.malformed("zlib: текст неправдоподобно велик")
    }

    /// adler32 по RFC 1950 — хвост zlib-потока (big-endian).
    private static func adler32BE(_ data: [UInt8]) -> [UInt8] {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let v = (b << 16) | a
        return [UInt8(v >> 24), UInt8((v >> 16) & 0xFF),
                UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}
