import Foundation

// ============================================================================
// Кодек позиции для эфира — ТОНКАЯ ОБЁРТКА над Envelope §5 (fine coords).
//
// Формат НЕ новый: точные координаты канонизированы в docs/RM_Envelope_v0.md
// §5 и реализованы в Envelope.encodeFineCoords / decodeFineCoords (обе оси
// ×16777215, floor(x+0.5), lat LE24 + lon LE24 = 6 байт, ~1.2 м / ~2.4 м).
// Второго формата координат в проекте быть не должно — поэтому здесь нет
// собственной арифметики, только делегирование и типобезопасная обёртка.
//
// Побайтовые векторы: tests/position_codec_vectors.json (генератор
// sim/position_codec_vectors_gen.py поверх sim/envelope.py).
// ============================================================================

nonisolated enum PositionCodec {

    /// Размер закодированной пары на эфире, байт.
    static let encodedSize = 6

    /// Кодирует пару координат в 6 канонических байт Envelope §5.
    /// Вход вне диапазонов (-90…90, -180…180) — ошибка, не зажим.
    static func encode(lat: Double, lon: Double) throws -> [UInt8] {
        try Envelope.encodeFineCoords(lat: lat, lon: lon)
    }

    /// Обратное преобразование. Требует ровно 6 байт.
    static func decode(_ data: [UInt8]) throws -> (lat: Double, lon: Double) {
        guard data.count == encodedSize else {
            throw EnvelopeError.tooShort("кодек позиции: нужно \(encodedSize) байт, получено \(data.count)")
        }
        return Envelope.decodeFineCoords(data[0...])
    }
}
