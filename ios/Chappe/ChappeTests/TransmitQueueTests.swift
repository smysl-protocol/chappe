import Foundation
import Testing
@testable import Chappe

// ============================================================================
// ЗАМОК на разрастание очереди передачи (живой прогон 03.08).
//
// На экране Dev владелец увидел «канал занят — жду окно эфира ·
// в очереди: 6291». Причина: насос повторов DeliveryManager докладывает
// пакеты каждые 2 с, а транспорт не отдаёт их, пока исчерпан бюджет
// эфирного времени, — очередь росла без предела и все свежие сообщения
// вставали в хвост за тысячами копий.
//
// Здесь проверяется арифметика бэкоффа и бюджета эфира: именно из их
// сочетания и рождался рост.
// ============================================================================

nonisolated struct TransmitQueueTests {

    @Test("бюджет эфира: пакет считается по реальной скорости пресета")
    func airtimeUsesRealisticSpeed() {
        let budget = AirtimeBudget(config: MeshConfig())
        // LONG_FAST = SF11/BW250/CR4:5 ≈ 134 Б/с (не 190, как было)
        #expect(budget.bytesPerSecond == 134)
        let seconds = budget.airtime(bytes: 134)
        #expect(seconds > 1.0 && seconds < 1.3,
                "134 Б должны занимать около секунды эфира")
    }

    @Test("бюджет исчерпывается и запрещает передачу")
    func budgetBlocksWhenSpent() {
        var budget = AirtimeBudget(config: MeshConfig())
        let now = Date()
        let freshOK = budget.canSend(bytes: 140, now: now)
        #expect(freshOK)
        // выжигаем часовой лимит (36 с по дьюти-циклу EU 868)
        for _ in 0..<40 { budget.record(bytes: 140, now: now) }
        let blocked = budget.canSend(bytes: 140, now: now)
        #expect(!blocked, "после лимита передача обязана блокироваться")
        let afterHour = budget.canSend(bytes: 140,
                                       now: now.addingTimeInterval(3601))
        #expect(afterHour, "через час окно снова открыто")
    }

    @Test("потолок очереди передачи задан и разумен")
    func queueCapExists() {
        #expect(MeshtasticLink.maxWaiting == 64)
        // 64 пакета × ~1 с эфира ≈ вдвое больше часового бюджета:
        // копить больше бессмысленно, отправитель повторит сам
        #expect(MeshtasticLink.maxWaiting * 1 > 36)
    }

    @Test("бэкофф повторов растёт и упирается в минуту")
    func retryBackoffGrows() {
        let d1 = DeliveryManager.retryDelay(afterAttempts: 1)
        let d3 = DeliveryManager.retryDelay(afterAttempts: 3)
        let d9 = DeliveryManager.retryDelay(afterAttempts: 9)
        #expect(d1 < d3, "пауза между повторами обязана расти")
        #expect(d9 == 60, "потолок паузы — минута")
    }

    @Test("повтор не раньше своей паузы")
    func retryRespectsBackoff() {
        var item = Outbox.QueuedMessage(
            entryID: UUID(), msgID: 7, packetsHex: ["00"],
            totalBytes: 1, contactID: "test")
        item.attempts = 3
        let now = Date()
        item.lastAttemptAt = now
        #expect(!DeliveryManager.isDue(item, now: now),
                "сразу после попытки повторять нельзя")
        #expect(DeliveryManager.isDue(
            item, now: now.addingTimeInterval(61)))
    }
}
