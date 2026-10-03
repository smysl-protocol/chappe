import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Шторм квитанций и хвост сна опроса (дневники поля 29.09):
// 1) одна и та же отметка «прочитано» уходила 5–7 раз за секунду —
//    retryReadReceipts зовётся тиком насоса (2 с), nearby-окном и
//    открытием чата одновременно, а штамп readAt ставится только по
//    подтверждению канала: между отправкой и confirm любой вызов слал
//    снова. Нужен in-flight-гейт: повтор — только если подтверждение
//    не пришло за receiptRetryAfter.
// 2) опрос релея спал фиксированно 12 с: переход фон→актив в середине
//    сна оставлял хвост до 12 с — те самые «7–10 секунд» владельца.
//    Сон стал квантовым: готовность опроса решает чистая pollDue.
// ============================================================================

@MainActor
struct ReceiptStormTests {

    @Test("in-flight-гейт: повтор отметки — только после таймаута")
    func receiptDueRespectsInflight() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(DeliveryManager.receiptDue(inflightAt: nil, now: now),
                "не в полёте — слать")
        #expect(!DeliveryManager.receiptDue(
                inflightAt: now.addingTimeInterval(-1), now: now),
                "послана секунду назад, подтверждение не успело — молчим")
        #expect(DeliveryManager.receiptDue(
                inflightAt: now.addingTimeInterval(
                    -DeliveryManager.receiptRetryAfter - 1), now: now),
                "подтверждение так и не пришло — честный повтор")
    }

    @Test("двойной вызов ретрая шлёт отметку ОДИН раз (шторм погашен)")
    func doubleRetrySendsOnce() async throws {
        let manager = DeliveryManager.shared
        let contactID = "storm_test_\(UUID().uuidString.prefix(8))"
        var entry = ChatEntry(kind: .incoming, text: "входящее")
        // wire уникален: ключ in-flight — голый wire, фиксированное
        // значение ловит чужой полёт от соседних тестов процесса
        entry.wireMsgID = Int.random(in: 20_000...60_000)
        HumanChatStore.upsertLog(entry, contactID: contactID)
        defer { HumanChatStore.purge(contactID: contactID) }

        // канал-инъекция: считает отправки, подтверждение НЕ приходит
        // (как в поле: confirm релея занимает сотни мс)
        nonisolated(unsafe) var sent = 0
        let counting: (_ p: [UInt8],
                       _ c: @escaping @Sendable (Bool) -> Void) -> Void = {
            _, _ in sent += 1
        }
        // первый заход — открытие чата (заводит должника), дальше два
        // «лишних» пинка, как в поле: тик насоса + nearby-окно
        manager.sendReadReceipts(contactID: contactID, appActive: true,
                                 sendOverride: counting)
        manager.retryReadReceipts(only: contactID, sendOverride: counting)
        manager.retryReadReceipts(only: contactID, sendOverride: counting)
        #expect(sent == 1, Comment(rawValue:
                "три вызова подряд (тик насоса + nearby-окно + открытие "
                + "чата) обязаны дать ОДНУ отправку — дневник 29.09 "
                + "показывал 5–7 дублей за секунду; вышло \(sent)"))
    }

    @Test("квант опроса: фон→актив не ждёт хвоста 12-секундного сна")
    func pollDueShrinksOnActivation() {
        #expect(!RelayTransport.pollDue(elapsed: 2.9, appActive: true))
        #expect(RelayTransport.pollDue(elapsed: 3.0, appActive: true))
        #expect(!RelayTransport.pollDue(elapsed: 3.0, appActive: false),
                "в фоне такт прежний, 12 с — батарея")
        #expect(RelayTransport.pollDue(elapsed: 12.0, appActive: false))
        // суть фикса: сон начался в фоне, человек открыл приложение —
        // накопленные 5 с уже больше активного такта, опрос немедленно
        #expect(RelayTransport.pollDue(elapsed: 5.0, appActive: true),
                Comment(rawValue: "хвост фонового сна не должен "
                + "удерживать активный опрос — поле 29.09: 7–10 с"))
    }
}
