import Foundation
import CryptoKit

// ============================================================================
// Номер сверки (WP1, 05.08.2026) — по образцу Signal/WhatsApp, велосипеда
// нет: numeric fingerprint из libsignal. 60 цифр = две половины по 30,
// каждая — от одного ключа; половины сортируются, поэтому обе стороны
// видят ОДИН номер. Стойкость ~112 бит (5200 итераций SHA-512) против
// 40 бит короткого id — короткий 8-символьный отпечаток остаётся
// ЛОКАЛЬНЫМ идентификатором (имя файла, список), границей безопасности
// не является; сверка людьми — только этим номером или QR.
//
// Отклонение от Signal, осознанное: стабильный идентификатор = сам
// ключ (у нас нет телефонных номеров). Совместимости с Signal не
// требуется — номер сверяют два экземпляра нашего приложения.
// ============================================================================

nonisolated enum SafetyNumber {

    /// Итерации Signal: >112 бит стойкости для 30-цифровой половины.
    static let iterations = 5200

    /// Половина номера от одного ключа: 30 цифр.
    /// digest₀ = версия(2 Б, нули) || ключ || идентификатор(=ключ),
    /// затем `iterations` раз digest = SHA-512(digest || ключ);
    /// первые 6 чанков по 5 Б → big-endian число % 100000 → 5 цифр.
    static func half(for key: Curve25519.KeyAgreement.PublicKey) -> String {
        let keyData = Data(key.rawRepresentation)
        var digest = Data([0, 0]) + keyData + keyData
        for _ in 0..<iterations {
            digest = Data(SHA512.hash(data: digest + keyData))
        }
        var out = ""
        let bytes = Array(digest)
        for chunk in 0..<6 {
            var value: UInt64 = 0
            for i in 0..<5 { value = value << 8 | UInt64(bytes[chunk * 5 + i]) }
            out += String(format: "%05d", value % 100_000)
        }
        return out
    }

    /// Полный номер пары: отсортированные половины — у обеих сторон
    /// одинаков независимо от того, кто «первый».
    static func digits(_ a: Curve25519.KeyAgreement.PublicKey,
                       _ b: Curve25519.KeyAgreement.PublicKey) -> String {
        [half(for: a), half(for: b)].sorted().joined()
    }

    /// Отображение: 12 групп по 5 цифр через пробел (переносами
    /// управляет UI).
    static func display(_ digits: String) -> String {
        stride(from: 0, to: digits.count, by: 5).map { start in
            let s = digits.index(digits.startIndex, offsetBy: start)
            let e = digits.index(s, offsetBy: 5,
                                 limitedBy: digits.endIndex) ?? digits.endIndex
            return String(digits[s..<e])
        }.joined(separator: " ")
    }

    // MARK: QR-сверка (взаимная: каждый показывает свой, сканирует чужой)

    /// Схема QR сверки — отдельная от карточки контакта: сканер сверки
    /// не должен путать «добавь меня» и «проверь меня».
    static let verifyScheme = "rm://verify/"

    /// Текст моего QR сверки: полный ключ (32 Б) — сверка по нему
    /// сильнее цифр (256 бит).
    static func verifyPayloadText(
        for key: Curve25519.KeyAgreement.PublicKey) -> String {
        verifyScheme + Data(key.rawRepresentation).base64EncodedString()
    }

    /// Разбор чужого QR сверки → 32 байта ключа; всё прочее — nil.
    static func parseVerify(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(verifyScheme) else { return nil }
        let base64 = String(trimmed.dropFirst(verifyScheme.count))
        guard let data = Data(base64Encoded: base64), data.count == 32
        else { return nil }
        return data
    }
}
