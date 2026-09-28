import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// WP1: номер сверки по образцу Signal/WhatsApp — 60 цифр, 12 групп
// по 5. Алгоритм (Signal numeric fingerprint, ~112 бит):
// digest₀ = версия(2 Б, 0) || ключ || идентификатор, затем 5200
// итераций SHA-512(digest || ключ); первые 6×5 Б → BE-число % 100000.
// Наше отклонение: идентификатор = сам ключ (телефонных номеров нет).
// Вектор — ИЗВНЕ (правило 4): посчитан python-ом (hashlib) до
// реализации, кросс-реализация.
// ============================================================================

struct SafetyNumberTests {

    private func key(_ bytes: [UInt8]) -> Curve25519.KeyAgreement.PublicKey {
        try! Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(bytes))
    }

    @Test("кросс-вектор python: половины и полный номер")
    func crossImplementationVector() {
        let ka = key(Array(1...32))                    // 0x01..0x20
        let kb = key(Array((1...32).reversed()))       // 0x20..0x01
        #expect(SafetyNumber.half(for: ka)
                == "786119266451635729542171773088")
        #expect(SafetyNumber.half(for: kb)
                == "552478822113238060253574269747")
        #expect(SafetyNumber.digits(ka, kb)
                == "552478822113238060253574269747"
                 + "786119266451635729542171773088")
    }

    @Test("симметрия: обе стороны видят один номер")
    func symmetricForBothSides() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey
        #expect(SafetyNumber.digits(a, b) == SafetyNumber.digits(b, a))
    }

    @Test("разные пары — разные номера, длина всегда 60 цифр")
    func distinctAndWellFormed() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey
        let c = Curve25519.KeyAgreement.PrivateKey().publicKey
        let ab = SafetyNumber.digits(a, b)
        let ac = SafetyNumber.digits(a, c)
        #expect(ab != ac)
        #expect(ab.count == 60)
        #expect(ab.allSatisfy { $0.isNumber })
    }

    @Test("отображение: 12 групп по 5 цифр")
    func displayGroups() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey
        let shown = SafetyNumber.display(SafetyNumber.digits(a, b))
        let groups = shown.split(separator: " ")
        #expect(groups.count == 12)
        #expect(groups.allSatisfy { $0.count == 5 })
    }

    @Test("QR сверки: свой payload разбирается, чужой ключ не совпадает")
    func verifyPayloadRoundTrip() {
        let a = Curve25519.KeyAgreement.PrivateKey().publicKey
        let text = SafetyNumber.verifyPayloadText(for: a)
        #expect(text.hasPrefix(SafetyNumber.verifyScheme))
        #expect(SafetyNumber.parseVerify(text) == a.rawRepresentation)
        let b = Curve25519.KeyAgreement.PrivateKey().publicKey
        #expect(SafetyNumber.parseVerify(text) != b.rawRepresentation)
        // мусор и карточка контакта — не сверка
        #expect(SafetyNumber.parseVerify("rm://contact/abcd") == nil)
        #expect(SafetyNumber.parseVerify("случайный текст") == nil)
    }
}
