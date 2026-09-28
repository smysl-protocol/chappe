import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// «Начать заново» (12.08): корень проблемы — Keychain переживает удаление
// приложения, поэтому переустановка возвращает ТУ ЖЕ личность и прошлый
// чат воскресает (друг досылает / релей переотдаёт в те же ящики).
// Настоящий сброс обязан СМЕНИТЬ личность (новый отпечаток → новые
// ящики). Стирание локальных данных покрыто ContactPurgeTests; здесь —
// сердце фикса: смена личности.
//
// Тест НЕ рушит общий keychain параллельных тестов: сид сохраняется до
// сброса и восстанавливается после. Замок сломом: убери Identity.reset()
// из freshStart — отпечаток не сменится.
// ============================================================================

@MainActor
struct AppResetTests {

    @Test("сброс личности МЕНЯЕТ отпечаток (новые релейные ящики)")
    func resetChangesIdentityFingerprint() throws {
        let savedSeed = Identity.exportSeedHex()   // вернём в конце
        defer { if let savedSeed { _ = Identity.restore(fromSeedHex: savedSeed) } }

        let before = try #require(Identity.myFingerprint())
        Identity.reset()
        let after = try #require(Identity.myFingerprint())
        #expect(before != after, Comment(rawValue:
                "отпечаток обязан смениться при сбросе — иначе те же "
                + "релейные ящики, и прошлый чат воскресает после "
                + "переустановки (Keychain переживает деинсталляцию)"))
    }

    // Полевое 13.08: после «Начать заново» на «Моём QR» висело
    // «Отклонённых предложений: 1» из прошлой жизни. Сброс обязан
    // стирать и отказы знакомства.
    //
    // freshStart() здесь звать НЕЛЬЗЯ: он сносит ОБЩЕЕ хранилище
    // (каталог Chats целиком) и валит параллельные тесты — так 13.08
    // receiptStampedOnlyOnConfirmedSend терял свой лог посреди прогона
    // (тот же принцип, по которому сосед выше зовёт узкий
    // Identity.reset(), а не freshStart). Замок держит СЛОЙ стирания
    // (clearAllDeclined); проводка freshStart→clearAllDeclined — на
    // код-ревью и полевом чеке «Моего QR» после сброса.
    @MainActor
    @Test("отказы знакомства стираемы подчистую (слой сброса)")
    func declinedIntroductionsClearable() {
        let declinedKey = "nearby.introduce.declined"
        let saved = UserDefaults.standard.stringArray(forKey: declinedKey)
        defer { UserDefaults.standard.set(saved, forKey: declinedKey) }

        UserDefaults.standard.set(["КЛЮЧ-ПРОШЛОЙ-ЖИЗНИ"], forKey: declinedKey)
        #expect(IntroduceCenter.shared.declinedCount == 1, "предусловие")
        IntroduceCenter.shared.clearAllDeclined()
        #expect(IntroduceCenter.shared.declinedCount == 0, Comment(rawValue:
                "«начать заново» обязан стирать отказы знакомства — "
                + "новая личность не наследует «не нужно» старой"))
    }
}
