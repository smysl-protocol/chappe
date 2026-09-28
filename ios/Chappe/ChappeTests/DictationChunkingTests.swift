import Foundation
import Testing
@testable import Chappe

// ============================================================================
// Нарезка и склейка длинных диктовок — поведенческие тесты поверх
// эталонного порта (сходимость с векторами — SpliceParityTests).
// ============================================================================

nonisolated struct DictationChunkingTests {

    // MARK: Склейка

    @Test("3 чанка → все три в итоге, по порядку")
    func joinerKeepsAllInOrder() {
        let joined = SpeechDictation.splice([
            (ok: true, text: "первая фраза"),
            (ok: true, text: "вторая фраза"),
            (ok: true, text: "третья фраза"),
        ])
        #expect(joined == "первая фраза вторая фраза третья фраза")
    }

    @Test("Отказ чанка → маркер […], ничего не отброшено молча")
    func joinerMarksFailedChunk() {
        #expect(SpeechDictation.splice([
            (ok: true, text: "A"), (ok: false, text: ""), (ok: true, text: "C"),
        ]) == "A […] C")
        #expect(SpeechDictation.splice([
            (ok: false, text: ""), (ok: true, text: "B"),
        ]) == "[…] B")
        #expect(SpeechDictation.splice([
            (ok: true, text: "A"), (ok: false, text: ""),
        ]) == "A […]")
    }

    @Test("Дедуп стыка: повтор слов перекрытия срезается, знаки не мешают")
    func seamDedup() {
        #expect(SpeechDictation.dedupJoinPair(
            "возьми три бутылки воды", "Бутылки воды и хлеб")
            == "возьми три бутылки воды и хлеб")
        // пунктуация на стыке не ломает дедуп (нормализация)
        #expect(SpeechDictation.dedupJoinPair(
            "поедем через мост", "Мост, встретимся у кафе")
            == "поедем через мост встретимся у кафе")
        // нет совпадения — просто склейка
        #expect(SpeechDictation.dedupJoinPair(
            "буду в семь", "воды три бутылки")
            == "буду в семь воды три бутылки")
    }

    // MARK: Ловушка частичного успеха

    @Test("Покрытие: конец сегментов против длительности файла")
    func coverageRatio() {
        // финал покрыл 30 с из 70 → 43% → частичный
        let partial = SpeechDictation.coverageRatio(
            segments: [(0, 12.5), (13.0, 17.0)], duration: 70)
        #expect(partial < 0.85)
        // почти до конца → полный
        let full = SpeechDictation.coverageRatio(
            segments: [(0, 30), (30.5, 37.5)], duration: 70)
        #expect(full >= 0.85)
        // сегментов нет (тайминги не пришли) → 0 → честно в нарезку
        #expect(SpeechDictation.coverageRatio(segments: [], duration: 40) == 0)
    }

    // MARK: Границы чанков

    @Test("Точка реза уезжает в самое тихое место окна ±3 с")
    func quietCutPointPrefersSilence() {
        // громко везде, но на 28.5 c — тишина
        let levels: [(t: Double, level: Double)] = stride(
            from: 25.0, through: 35.0, by: 0.5).map { t in
            (t, t == 28.5 ? -60 : -20)
        }
        let cuts = SpeechDictation.pickCutPoints(levels: levels, duration: 40)
        #expect(cuts == [28.5])
        // пустой таймлайн — режем ровно по цели
        #expect(SpeechDictation.pickCutPoints(levels: [], duration: 40) == [30])
    }

    @Test("Границы чанков: перекрытие 1 с, всё покрыто, хвост не теряется")
    func chunkRangesOverlapAndCoverage() {
        let ranges = SpeechDictation.chunkRanges(duration: 70)
        #expect(ranges.count == 3)
        #expect(ranges[0].start == 0)
        // каждый следующий начинается на 1 с раньше конца предыдущего
        for i in 1..<ranges.count {
            let prevEnd = ranges[i - 1].start + ranges[i - 1].duration
            #expect(abs(ranges[i].start - (prevEnd - 1)) < 0.001,
                    "перекрытие 1 с на стыке \(i)")
        }
        // последний чанк дотягивает до конца файла
        let last = ranges.last!
        #expect(abs(last.start + last.duration - 70) < 0.001)
        // короткий хвост (<5 с за целью) не отделяется
        let short = SpeechDictation.chunkRanges(duration: 33)
        #expect(short.count == 1)
        #expect(short[0].duration == 33)
    }
}
