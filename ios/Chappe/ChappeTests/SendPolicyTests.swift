import Foundation
import Testing
import CryptoKit
@testable import Chappe

// ============================================================================
// А1 (09.08, замер на живом Release: модель 2,4–4,8 с, быстрый путь
// 14,5 мс): пивот бежит ТОЛЬКО к LoRa — единственному пути, где байты
// дороже секунд. Быстрые транспорты (релей, BLE «рядом», Wi-Fi Aware)
// идут текстом без модели; E2E-шифр одинаков. Прежняя доктрина WP1
// (05.08) с relayEnabled и «сосед = узкий путь» упразднена владельцем.
// Политика — чистой функцией (таблица истинности — замок), решение
// закодировано ОДНАЖДЫ до кодека: перекодирования вдогонку нет по
// построению (инвариант дедупа: один msgID — один внутренний payload
// обоими путями).
// ============================================================================

// .serialized: тесты делят transport_kind (DeliveryManager.shared) —
// параллельный прогон внутри сюиты гонял mesh против demo
@Suite(.serialized)
struct SendPolicyTests {

    @Test("таблица истинности: пивот бежит только к LoRa")
    func truthTable() {
        // адресное + LoRa настроен → узкий путь в игре, кодек ради байтов
        #expect(SendPolicy.pivotWorthRunning(hasContact: true,
                                             loRaConfigured: true))
        // адресное, LoRa нет → быстрые пути, модель — чистая задержка
        #expect(!SendPolicy.pivotWorthRunning(hasContact: true,
                                              loRaConfigured: false))
        // СОСЕД РЯДОМ НЕ ВКЛЮЧАЕТ КОДЕК (А1, 09.08): BLE — быстрый
        // транспорт, ждать модель 2,4–4,8 с ради него запрещено
        #expect(!SendPolicy.pivotWorthRunning(hasContact: true,
                                              loRaConfigured: false,
                                              nearbyNow: true))
        // с LoRa кодек бежит и при соседе (LoRa в игре — байты дороже)
        #expect(SendPolicy.pivotWorthRunning(hasContact: true,
                                             loRaConfigured: true,
                                             nearbyNow: true))
        // широковещательное (демо/эфир) — радио-путь по построению
        #expect(SendPolicy.pivotWorthRunning(hasContact: false,
                                             loRaConfigured: false))
    }

    @Test("конвейер модели минует пивот на чисто-релейном пути")
    @MainActor
    func modelPipelineShortCircuits() async {
        // транспорт по умолчанию — demo (радио не сконфигурировано)
        let saved = UserDefaults.standard.string(forKey: "transport_kind")
        UserDefaults.standard.set("demo", forKey: "transport_kind")
        defer { UserDefaults.standard.set(saved, forKey: "transport_kind") }
        DeliveryManager.shared.transportKind = "demo"

        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        let contact = Contact(id: Identity.fingerprint(of: key),
                              name: "Тест WP1",
                              publicKeyBase64: key.rawRepresentation
                                  .base64EncodedString(),
                              addedAt: Date(), verified: nil)
        let model = HumanChatModel(contact: contact)
        let outcome = await model.pipeline(
            "длинное сообщение которое раньше ждало пивот четыре секунды")
        guard case .text(let reason, let needsCard) = outcome else {
            Issue.record("ожидался мгновенный текст, получено \(outcome)")
            return
        }
        #expect(reason == SendPolicy.skipReason,
                "не та ветка: \(reason) — пивот, похоже, бежал")
        #expect(!needsCard, "пропуск пивота — не повод для карточки")
    }

    @Test("LoRa настроен — политика кодек НЕ пропускает")
    @MainActor
    func loRaPathRunsCodec() async {
        let saved = UserDefaults.standard.string(forKey: "transport_kind")
        UserDefaults.standard.set("mesh", forKey: "transport_kind")
        defer { UserDefaults.standard.set(saved, forKey: "transport_kind") }
        DeliveryManager.shared.transportKind = "mesh"
        defer { DeliveryManager.shared.transportKind = "demo" }

        let key = Curve25519.KeyAgreement.PrivateKey().publicKey
        let contact = Contact(id: Identity.fingerprint(of: key),
                              name: "Тест-ЛоРа",
                              publicKeyBase64: key.rawRepresentation
                                  .base64EncodedString(),
                              addedAt: Date(), verified: nil)
        let model = HumanChatModel(contact: contact)
        let outcome = await model.pipeline(
            "длинное сообщение ради узкого радио пути с кодеком")
        // кодек мог отказать по-честному (нет модели в симуляторе) —
        // замок держит одно: ПОЛИТИКА пропуск не выдала
        if case .text(let reason, _) = outcome {
            #expect(reason != SendPolicy.skipReason, Comment(rawValue:
                    "на LoRa-пути политика пропустила кодек — байты "
                    + "уйдут несжатыми в узкий эфир (А1, 09.08)"))
        }
    }

    @Test("время текстового пути после пропуска — миллисекунды, не секунды")
    func textPathIsInstant() {
        let text = String(repeating: "координаты моста и время сбора. ",
                          count: 10)   // ~340 байт — «длинный» случай
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 { _ = TextCodec.best(text) }
        }
        // 10 прогонов min(store, zlib) обязаны укладываться в 100 мс
        // с огромным запасом (фактически — микросекунды на прогон)
        #expect(elapsed < .milliseconds(100),
                "текстовый путь неожиданно дорог: \(elapsed)")
    }
}
