import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Дневник транспорта (03.08): полевой отказ «шлю, но не принимаю»
// отлаживался вслепую — приложение не оставляло следов, завершился ли
// хендшейк и что узел отвечал на чтения. Дневник пишет события канала
// в Documents (File Sharing включён — забирается с Мака), хвостом
// ограниченного размера.
// ============================================================================

nonisolated struct TransportDiaryTests {

    @Test("короткий дневник не обрезается")
    func shortDiaryUntouched() {
        let text = "строка раз\nстрока два\n"
        #expect(TransportDiary.trimmed(text, maxBytes: 1024) == text)
    }

    @Test("длинный дневник теряет начало, конец цел")
    func longDiaryKeepsTail() {
        let lines = (0..<100).map { "событие номер \($0)" }
        let text = lines.joined(separator: "\n") + "\n"
        let cut = TransportDiary.trimmed(text, maxBytes: 300)
        #expect(cut.utf8.count <= 300)
        #expect(cut.hasSuffix("событие номер 99\n"),
                "свежие события обязаны выжить")
        #expect(!cut.contains("событие номер 0\n"),
                "старьё уходит первым")
    }

    @Test("обрезка не рвёт строку посередине")
    func trimCutsAtLineBoundary() {
        let text = String(repeating: "ааа\n", count: 100)
        let cut = TransportDiary.trimmed(text, maxBytes: 50)
        #expect(cut.isEmpty || cut.hasPrefix("ааа"),
                "после обрезки первая строка целая")
    }
}
