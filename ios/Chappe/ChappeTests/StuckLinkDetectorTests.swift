import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Детектор клина отдачи узла (решение владельца 03.08: «тишина не есть
// работа» — приложение обязано заметить и сказать, а не молчать).
//
// Наблюдаемый изнутри приложения признак клина: счётчик FromNum узла
// растёт (пакеты копятся), а данных из FromRadio нет дольше разумного.
// FromNum читается пульсом (свойство READ у характеристики), поэтому
// у детектора есть и второй вердикт: узел вовсе перестал отвечать на
// чтения при живой записи.
// ============================================================================

nonisolated struct StuckLinkDetectorTests {

    @Test("первое значение счётчика — базовая линия, не тревога")
    func firstValueIsBaseline() {
        var d = StuckLinkDetector()
        let now = Date()
        d.noteFromNum(41, now: now)
        #expect(d.verdict(now: now.addingTimeInterval(60)) == nil,
                "рост не наблюдался — тревожить не с чего")
    }

    @Test("счётчик вырос и данные пришли — всё здорово")
    func advanceThenDataIsHealthy() {
        var d = StuckLinkDetector()
        let now = Date()
        d.noteFromNum(41, now: now)
        d.noteFromNum(42, now: now.addingTimeInterval(5))
        d.noteData(now: now.addingTimeInterval(6))
        #expect(d.verdict(now: now.addingTimeInterval(60)) == nil)
    }

    @Test("счётчик вырос, данных нет дольше срока — клин")
    func advanceWithoutDataIsStuck() {
        var d = StuckLinkDetector()
        let now = Date()
        d.noteFromNum(41, now: now)
        d.noteFromNum(42, now: now.addingTimeInterval(5))
        let later = now.addingTimeInterval(
            5 + StuckLinkDetector.dataGrace + 1)
        #expect(d.verdict(now: later) == .queueStuck)
    }

    @Test("до истечения срока ожидания данных тревоги нет")
    func graceBeforeVerdict() {
        var d = StuckLinkDetector()
        let now = Date()
        d.noteFromNum(41, now: now)
        d.noteFromNum(42, now: now.addingTimeInterval(5))
        #expect(d.verdict(now: now.addingTimeInterval(7)) == nil,
                "чтение после notify занимает секунды — это норма")
    }

    @Test("данные после клина снимают тревогу")
    func dataClearsStuck() {
        var d = StuckLinkDetector()
        let now = Date()
        d.noteFromNum(41, now: now)
        d.noteFromNum(42, now: now.addingTimeInterval(5))
        let stuckAt = now.addingTimeInterval(5 + StuckLinkDetector.dataGrace + 1)
        #expect(d.verdict(now: stuckAt) == .queueStuck)
        d.noteData(now: stuckAt.addingTimeInterval(1))
        #expect(d.verdict(now: stuckAt.addingTimeInterval(2)) == nil)
    }

    @Test("узел молчит на несколько пульсов подряд — недоступен")
    func unansweredPulsesMeanUnresponsive() {
        var d = StuckLinkDetector()
        let now = Date()
        d.noteFromNum(41, now: now)   // когда-то отвечал
        for i in 0..<StuckLinkDetector.unansweredPulsesLimit {
            d.notePulseSent(now: now.addingTimeInterval(Double(i) * 15))
        }
        #expect(d.verdict(now: now.addingTimeInterval(60)) == .unresponsive)
    }

    @Test("ответ на пульс обнуляет счёт неотвеченных")
    func pulseAnswerResetsCount() {
        var d = StuckLinkDetector()
        let now = Date()
        d.notePulseSent(now: now)
        d.notePulseSent(now: now.addingTimeInterval(15))
        d.noteFromNum(41, now: now.addingTimeInterval(16))
        d.notePulseSent(now: now.addingTimeInterval(30))
        #expect(d.verdict(now: now.addingTimeInterval(31)) == nil,
                "после ответа счёт начинается заново")
    }
}
