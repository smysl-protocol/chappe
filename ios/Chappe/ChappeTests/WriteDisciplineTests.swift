import Foundation
import Testing
@testable import Chappe

// ============================================================================
// ЗАМОК на клин отдачи узла (диагноз 03.08,
// docs/reports/reception_diagnosis_2026-08-03.md).
//
// Воспроизведено трижды: подключение → залп накопленной очереди узла →
// глухота к новым пакетам до разрыва BLE. Провокатор — шквал записей
// ToRadio во время дренажа FromRadio: ack на каждый принятый пакет
// мгновенно + весь outbox залпом при каждом запуске.
//
// Дисциплина, которую фиксируют эти тесты:
//   1. DrainGate — «сначала дочитать, потом писать»: пока узел отдаёт
//      очередь, записи ждут; пустое чтение открывает окно записи;
//      застрявший дренаж не блокирует запись вечно (тишина не есть
//      отказ — у ворот есть пульс-таймаут).
//   2. WritePacer — записи в ToRadio идут с паузой, не очередью залпом.
//   3. Дозирование outbox — насос повторов отдаёт в канал не больше
//      N сообщений за проход, а не все 31 разом.
//   4. AckAggregator — подтверждения копятся и уходят после окна
//      тишины приёма, а не вперемешку с дренажом.
// ============================================================================

nonisolated struct WriteDisciplineTests {

    // MARK: DrainGate

    @Test("до первого чтения записывать можно")
    func gateStartsOpen() {
        let gate = DrainGate()
        #expect(gate.canWrite(now: Date()))
    }

    @Test("во время дренажа запись закрыта, пустое чтение открывает")
    func gateClosesDuringDrainOpensOnEmpty() {
        var gate = DrainGate()
        let now = Date()
        gate.noteReadRequested(now: now)
        #expect(!gate.canWrite(now: now), "дренаж идёт — писать нельзя")
        gate.noteData(now: now.addingTimeInterval(1))
        #expect(!gate.canWrite(now: now.addingTimeInterval(1)),
                "данные идут — дренаж продолжается")
        gate.noteEmptyRead()
        #expect(gate.canWrite(now: now.addingTimeInterval(2)),
                "очередь узла пуста — окно записи открыто")
    }

    @Test("застрявший дренаж не запирает запись навсегда")
    func gateStallTimeoutOpens() {
        var gate = DrainGate()
        let now = Date()
        gate.noteReadRequested(now: now)
        let stalled = now.addingTimeInterval(DrainGate.stallTimeout + 1)
        #expect(gate.canWrite(now: stalled),
                "ответ на чтение потерялся — после таймаута пишем")
    }

    @Test("новое чтение после паузы снова закрывает ворота")
    func gateRecloses() {
        var gate = DrainGate()
        let now = Date()
        gate.noteReadRequested(now: now)
        gate.noteEmptyRead()
        gate.noteReadRequested(now: now.addingTimeInterval(5))
        #expect(!gate.canWrite(now: now.addingTimeInterval(5)))
    }

    // MARK: WritePacer

    @Test("первая запись сразу, вторая ждёт свой зазор")
    func pacerSpacesWrites() {
        var pacer = WritePacer()
        let now = Date()
        #expect(pacer.delayUntilFree(now: now) == 0,
                "первой записи ждать нечего")
        pacer.noteWrite(now: now)
        #expect(pacer.delayUntilFree(now: now) >= WritePacer.minGap * 0.99,
                "вторая запись в тот же миг обязана ждать зазор")
        pacer.noteWrite(now: now)
        #expect(pacer.delayUntilFree(now: now) >= WritePacer.minGap * 1.99,
                "залп сериализуется: каждый следующий позже предыдущего")
    }

    @Test("после паузы длиннее зазора записи снова без ожидания")
    func pacerResetsAfterGap() {
        var pacer = WritePacer()
        let now = Date()
        pacer.noteWrite(now: now)
        let later = now.addingTimeInterval(WritePacer.minGap * 3)
        #expect(pacer.delayUntilFree(now: later) == 0)
    }

    // MARK: дозирование outbox

    @Test("насос отдаёт в канал не больше лимита за проход")
    func pumpPassIsCapped() {
        let now = Date()
        let queue = (0..<31).map { i in
            Outbox.QueuedMessage(
                entryID: UUID(), msgID: UInt16(i), packetsHex: ["00"],
                totalBytes: 1, contactID: "test")
        }
        let picked = DeliveryManager.pickDue(
            queue: queue, now: now, limit: DeliveryManager.sendsPerPass)
        #expect(picked.count == DeliveryManager.sendsPerPass,
                "31 готовое сообщение не должно уходить залпом")
        #expect(picked == Array(0..<DeliveryManager.sendsPerPass),
                "порядок очереди сохраняется: первые — первыми")
    }

    @Test("лимит не мешает, когда готовых меньше лимита")
    func pumpPassUnderLimit() {
        let now = Date()
        var early = Outbox.QueuedMessage(
            entryID: UUID(), msgID: 1, packetsHex: ["00"],
            totalBytes: 1, contactID: "test")
        var waiting = Outbox.QueuedMessage(
            entryID: UUID(), msgID: 2, packetsHex: ["00"],
            totalBytes: 1, contactID: "test")
        waiting.attempts = 3
        waiting.lastAttemptAt = now       // пауза бэкоффа не прошла
        let picked = DeliveryManager.pickDue(
            queue: [early, waiting], now: now,
            limit: DeliveryManager.sendsPerPass)
        #expect(picked == [0], "не готовые по бэкоффу не берутся")
    }

    @Test("лимит за проход задан и разумен")
    func sendsPerPassIsSane() {
        // насос тикает каждые 2 с: лимит 2 → не больше сообщения в
        // секунду — узел успевает и передавать, и слушать эфир
        #expect(DeliveryManager.sendsPerPass >= 1)
        #expect(DeliveryManager.sendsPerPass <= 3)
    }

    // MARK: AckAggregator

    @Test("во время залпа приёма ack не уходят")
    func acksHeldDuringBurst() {
        var acks = AckAggregator()
        let now = Date()
        acks.add(10, now: now)
        acks.add(11, now: now.addingTimeInterval(1))
        #expect(acks.takeDue(now: now.addingTimeInterval(1.5)).isEmpty,
                "окно тишины не прошло — подтверждениям рано")
    }

    @Test("после окна тишины уходят все накопленные, без дублей")
    func acksFlushAfterQuiet() {
        var acks = AckAggregator()
        let now = Date()
        acks.add(10, now: now)
        acks.add(11, now: now.addingTimeInterval(1))
        acks.add(10, now: now.addingTimeInterval(1))   // дубль повтора
        let due = acks.takeDue(
            now: now.addingTimeInterval(1 + AckAggregator.quietWindow + 0.1))
        #expect(due == [10, 11], "все накопленные, каждый один раз")
        #expect(acks.takeDue(now: now.addingTimeInterval(60)).isEmpty,
                "после сдачи копилка пуста")
    }

    @Test("бесконечный поток приёма не задерживает ack дольше потолка")
    func acksMaxHoldForcesFlush() {
        var acks = AckAggregator()
        let start = Date()
        // приём капает чаще окна тишины — тишина не наступает никогда
        var t: TimeInterval = 0
        var id: UInt16 = 0
        while t < AckAggregator.maxHold + 2 {
            acks.add(id, now: start.addingTimeInterval(t))
            let due = acks.takeDue(now: start.addingTimeInterval(t))
            if !due.isEmpty {
                #expect(t >= AckAggregator.maxHold,
                        "раньше потолка сдача не обязана случиться")
                return
            }
            t += AckAggregator.quietWindow / 2
            id += 1
        }
        Issue.record("потолок удержания не сработал — ack не ушли вовсе")
    }
}
