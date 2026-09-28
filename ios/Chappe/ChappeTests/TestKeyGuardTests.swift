import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// WP4 (бриф 05.08): тестовые ключи не могут использоваться в проде —
// ЗАМКОМ, не комментарием. Ключи кросс-векторов шаблонные (лесенка
// 01..20, повтор a0..af ×2, RelayClientTests), плюс вырожденные
// (все байты равны). Прод-пути — разбор карточки контакта и
// восстановление сида с бумаги — обязаны их отвергать. Слом гейта
// (isTestVectorKey → false) красит эти тесты.
// ============================================================================

struct TestKeyGuardTests {

    private func card(keyBytes: [UInt8]) -> String {
        let json = ["v": 1, "name": "Вектор",
                    "pub": Data(keyBytes).base64EncodedString()] as [String: Any]
        return try! JSONSerialization.data(withJSONObject: json)
            .base64EncodedString()
    }

    @Test("лесенка кросс-векторов (01..20) не проходит как контакт")
    func ladderKeyIsRejected() {
        #expect(ContactStore.parse(card(keyBytes: (1...32).map(UInt8.init)))
                == nil)
        // и обратная лесенка (вектор SafetyNumberTests)
        #expect(ContactStore.parse(
            card(keyBytes: (1...32).reversed().map(UInt8.init))) == nil)
    }

    @Test("вырожденный ключ (все байты равны) не проходит как контакт")
    func degenerateKeyIsRejected() {
        #expect(ContactStore.parse(
            card(keyBytes: [UInt8](repeating: 0, count: 32))) == nil)
        #expect(ContactStore.parse(
            card(keyBytes: [UInt8](repeating: 0xA7, count: 32))) == nil)
    }

    @Test("повтор короткого шаблона (a0..af ×2) не проходит как контакт")
    func repeatingPatternKeyIsRejected() {
        let pairKey = (0..<32).map { UInt8(0xA0 + $0 % 16) }
        #expect(ContactStore.parse(card(keyBytes: pairKey)) == nil)
    }

    @Test("настоящий случайный ключ проходит")
    func realKeyStillParses() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        #expect(ContactStore.parse(
            card(keyBytes: Array(key.rawRepresentation))) != nil)
    }

    @Test("восстановление сида отвергает вырожденные и лесенку")
    func restoreRejectsDegenerateSeeds() {
        // при сломанном гейте restore ЗАПИШЕТ сид — вернуть личность
        // симулятора обязательно (иначе красный тест портит соседей)
        let saved = Identity.exportSeedHex()
        defer { if let saved { _ = Identity.restore(fromSeedHex: saved) } }
        #expect(!Identity.restore(fromSeedHex: String(repeating: "00",
                                                      count: 32)))
        let ladder = (1...32).map { String(format: "%02x", $0) }.joined()
        #expect(!Identity.restore(fromSeedHex: ladder))
    }
}
